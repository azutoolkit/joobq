# One million no-op completions per minute

The target is 1,000,000 **confirmed completed jobs in at most 60 seconds** on the
current host. This is a finite burst test, not a claim that arbitrary application
handlers or indefinitely retained queues sustain that rate.

## Measured results — 2026-10-29

Crystal 1.22.1, Redis 8.0.2; five visible CPUs, cgroup quota equivalent to four
cores, 32 GiB memory limit. Two independent Redis primaries share this same host
with two runtime processes, each configured with `CRYSTAL_WORKERS=2`, four
producers, 512 leased slots and 128-job batches. Payloads are 64 bytes. Verified
TLS, AOF `always`, and automatic AOF rewriting remain enabled.

| Run | Confirmed completed | Wall time including fixtures | Completed/minute |
| --- | ---: | ---: | ---: |
| [1](evidence/million-per-minute-run1-2026-10-29.json) | 1,000,000 | 39.55 s | 1,517,198 |
| [2](evidence/million-per-minute-run2-2026-10-29.json) | 1,000,000 | 37.10 s | 1,617,033 |
| [3](evidence/million-per-minute-run3-2026-10-29.json) | 1,000,000 | 32.74 s | 1,832,708 |

All three runs passed the actual million-completions-within-a-minute gate.
The median was **1.62 million/minute**; even the slowest run exceeded the target.
These are elapsed-time rates for finite bursts, not a sustained multi-hour rate.
No accepted ID was missing, no handler count differed, and every final receipt
had exactly one attempt. This fault-free observation is not an exactly-once
external-effects guarantee.

The preceding single-primary, million-job run took 68.35 s (14,630/s), missing
the target. Redis used approximately one full CPU core; partitioning makes use
of additional cores on the existing host. The single-primary diagnostic and
before/after TCP_NODELAY measurements are retained in the
[diagnostic manifest](evidence/million-diagnostics-2026-10-29.json).

A [two-partition 1 KiB run](evidence/million-1kib-2026-10-29.json) completed all
1,000,000 jobs in **60.37 seconds**, or 993,807/minute. Its strict target check
failed. The successful 64-byte measurements must not be generalized to this
larger workload or used to conceal that failed gate.

Using **three independent partitions on the same host**, the
[1 KiB workload](evidence/million-1kib-three-partitions-2026-10-29.json) completed
all 1,000,000 jobs in **50.91 seconds**, or **1,178,549/minute**, passing the
strict gate. This configuration still uses two Crystal execution threads per
partition, 128-job batches and the same TLS/persistence settings. It uses more
of this machine's available CPU budget; it does not add hardware or remote Redis.
A [repeat with the same configuration](evidence/million-1kib-three-partitions-repeat-2026-10-29.json)
also passed: **52.25 seconds**, or **1,148,364/minute**, with all 1,000,000 jobs
confirmed. Neither 1 KiB result relies on extrapolating a smaller job count.

## Implementation

The schema-1 ledger now has bounded `admit_many`, `claim_many`, `settle_many` and
`resolve_many` operations. Limits are 128 items per call and 2 MiB of aggregate
payload for admission/settlement. Optimized claims also cap aggregate payload at
2 MiB. Every item retains its own ID, payload checksum, ownership token, attempt,
server-side lease deadline, and canonical receipt. Batch settlement can mix
Completed, Dead and Scheduled results. Resolve reads still validate every record.

These operations are **not all-or-nothing transactions**. Redis script failure
can leave a persisted prefix; the client reports Unknown rather than replaying
the mutation. Resolve each stable request ID, and let canonical-record repair
restore derived indexes. Claim replies lost in transit leave leases which expire
and recover normally. Only a confirmed NOSCRIPT permits script reload/retry.
Large Int64 metadata retains the exact existing CAS fallback.

`Runtime.new(..., batch_size: 128, capacity: 512)` opts into short-job batching.
Four worker fibers each reserve up to 128 leased slots. Handlers run sequentially
within each group; independent groups execute concurrently. All claimed jobs,
including jobs waiting for execution or acknowledgment, participate in renewal.
The reserved total never exceeds `capacity`. Slow handlers can delay the rest of
their group: the default `batch_size: 1` remains appropriate for heterogeneous or
I/O-heavy application jobs. Shutdown cancels contexts after its deadline and
leaves unacknowledged leases recoverable. It never kills user fibers.

`runtime.admit_many("work", [{"request-1", "payload"}, {"request-2", "payload"}])`
returns one admission result per input. When telemetry is enabled, this API uses
individual admissions to preserve per-job publish spans. Processing spans remain
per job in either execution mode. Benchmarks have external telemetry disabled.

TCP connections now use TCP_NODELAY. Without it, requests spanning TLS records
showed approximately 40 ms stalls. With it, the same 100,000-job, 1 KiB batch
workload improved from 2,642 to 9,365 confirmed completions/s. The optimized index
writer updates sorted-set scores directly instead of removing and reinserting
the same membership, preserving canonical-first repair semantics.

## Reproduction

```sh
crystal build benchmarks/leased.cr --release -o /tmp/joobq-leased
CRYSTAL_WORKERS=2 python3 scripts/benchmark_million.py \
  --binary /tmp/joobq-leased --partitions 2 --jobs 1000000 \
  --batch-size 128 --capacity 512 --producers 4 --payload-bytes 64 \
  --output /tmp/million-completions.json --require-target
```

The runner starts two **independent Redis primaries and runtime processes on the
same machine**. Each owns half the job identities. It provisions its own test CAs
and verified TLS connections, AOF `always`, and no-eviction Redis fixtures. The
aggregate elapsed time includes fixture startup and cleanup, not just handler
execution. The benchmark verifies each accepted ID is Completed with attempt 1
and that handler executions equal accepted jobs. A missing completion, duplicate
execution, timeout or failed target exits nonzero when `--require-target` is set.
Redis automatic AOF rewriting remains enabled.

This is explicit workload partitioning across independent stores, not Redis
Cluster/Sentinel support or an automatic cross-partition transaction/router.
Applications must route a stable request ID to the same owning store and avoid
assuming atomic batches or workflow coordination across stores.

For the larger 1 KiB workload, use `--partitions 3 --payload-bytes 1024` with the
same command. Two partitions narrowly missed that workload's target.

The raw no-op handler only increments an execution counter; it performs no
business I/O or typed-job deserialization. The 64-byte payload configuration is
reported explicitly and must not be confused with the earlier 1 KiB workloads.
Use `--payload-bytes 1024` to measure that workload separately.

## Capacity limits

The benchmark increases `max_records` to the number assigned to each partition
and retains every receipt through verification. It does not delete receipts to
pass. Those finite stores would refuse further distinct admissions at capacity.
Safe retention/archival and a sustained soak remain necessary for an indefinite
million-per-minute service. This result alone does not certify enterprise v1,
HA failover, or real application throughput.

## Correctness validation

The modified core passed **554 examples, zero failures/errors/pending**. The
paired Pro worktree passed **414 examples, zero failures/errors/pending** against
this core, both with six configured Crystal workers and the owned Redis 8.0.2
URL/TLS fixtures. The Pro check used the local core worktree, not a new remote
dependency pin. Formatting, Python syntax and whitespace checks also passed.

New regression cases cover per-item admission conflicts and capacity, expired
ownership, retry scheduling, partial writes and repair, exact Int64 fallback,
corruption preservation, payload replacement with a valid checksum, script-cache
eviction, batch renewal and bounded shutdown. A batch-size-eight process probe
conserved 20/20 completions and distinct effects after SIGKILL (28 attempts), and
8/8 after SIGTERM (16 attempts; approximately 114 ms bounded incomplete drain).
Replacement workers exited cleanly on SIGINT. CI now includes that batch probe
on the four-worker URL lanes. See the [validation manifest](evidence/million-validation-2026-10-29.json).

These changes and evidence are local and uncommitted; hosted CI has not run on
this implementation. The older green PR checks do not validate these new patches.
