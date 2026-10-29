# Delivery allocation optimization — 2026-10-29

Three runs per configuration, 30,000 jobs per run, 1 KiB payloads, verified TLS
and Redis AOF `always`. Each run owns its Redis fixtures. The before/after runs
conserved all **360,000 accepted IDs**, with exactly one handler execution and
attempt per job. Crystal 1.22.1 / Redis 8.0.2 on the same host.

| Configuration | Before allocated bytes/job | After allocated bytes/job | Reduction | Before completions/s | After completions/s |
| --- | ---: | ---: | ---: | ---: | ---: |
| Single, 4 threads, 16 producers/slots | 24,714 | 18,104 | **26.7%** | 4,565 | 4,494 |
| Batch 128, 2 threads, 4 producers/512 slots | 22,863 | 15,454 | **32.4%** | 10,099 | 10,522 |

Values are medians. Allocation means `GC.stats.total_bytes` delta across the
entire benchmark: producers, runtime, Redis client and receipt reconciliation.
It excludes native-library allocations and the Redis server. This is neither
zero allocation nor an isolated count of handler allocations. Throughput remains
comparable; small speed changes should not be overinterpreted on a shared host.
Before runs preceded after runs, so timing may include host/cache drift.

The full same-host, three-partition **1 KiB / 1,000,000-job** workload also passed
after optimization: **43.98 seconds including fixture startup/cleanup**, or
**1,364,321 confirmed completions/minute**. Every accepted job completed with
one execution and attempt. See the [full-run manifest](evidence/delivery-allocation-million-2026-10-29.json).
This remains a finite no-op workload, not a sustained retention/soak certificate.

[Raw measurements and binary hashes](evidence/delivery-allocations-2026-10-29.json)
identify the exact executables. The baseline is the preceding uncommitted
million-job implementation, not the older branch HEAD. Local executables are
`/tmp/joobq-million-final` (before) and `/tmp/joobq-allocation-after` (after).

## Changes

- New admissions receive a compact acknowledgment containing the server-assigned
  due time, avoiding transmission and reparsing of a record already owned by the
  caller. Duplicate IDs still return and validate the actual stored receipt,
  including terminal state. Partial writes still report Unknown.
- Record encoding supplies a capacity hint to Crystal's standard JSON serializer.
  Escaping, UTF-8, schema and field semantics remain unchanged. Buffers can grow
  for escaped payloads; no custom JSON parser or unsafe string views were added.
- SHA256 validation uses a call-local stack buffer for its hex digest, avoiding
  temporary digest strings/byte arrays. Each call owns its digest context; no
  mutable cryptographic state is shared between fibers.
- Batch argument arrays reserve their required size and append directly, without
  creating an intermediate argument array for each job. Batch settlement replies
  contain integer statuses rather than nested one-element arrays.
- Runtime batch bookkeeping uses one array of value-type execution records plus
  two bounded settlement arrays, replacing eight parallel/scratch arrays.
  Handler exception handling is shared with the scalar runtime path.
- State and metric names use fixed strings rather than per-job formatting.
  The renewal scanner reuses its own bounded snapshot array.

Public admission/settlement return types and the schema-1 stored format are
unchanged. Script reply changes are private to their new content-addressed Lua
scripts. Old and new clients can share the same canonical records.

Contexts and active leases intentionally remain independently owned objects.
Handlers can retain a context, and renewal operations can outlive handler return.
Recycling those objects would risk crossing lease/job boundaries. Checksums,
lease deadlines, ownership fencing, original corrupt-record preservation and
unknown-outcome handling remain in place.

## Reproduction

```sh
crystal build benchmarks/leased.cr --release -o /tmp/joobq-allocation-after
BENCH_JOBS=30000 BENCH_BATCH_SIZE=128 BENCH_CAPACITY=512 \
  BENCH_PRODUCERS=4 BENCH_PAYLOAD_BYTES=1024 CRYSTAL_WORKERS=2 \
  python3 scripts/run_integration.py --probe /tmp/joobq-allocation-after
crystal run benchmarks/allocations.cr --release
```

Repeat the first workload three times for each executable. For the scalar
profile use batch size 1, capacity/producers 16 and four execution threads.
`allocations.cr` isolates encoding/validation costs without Redis operations;
its numbers are diagnostic and are not throughput measurements.

The component profile measured 3,968 bytes for default JSON encoding versus
2,528 bytes with a capacity hint, and 230 bytes for allocating a SHA256 hex digest
versus 96 bytes for checksum validation with stack scratch storage. These are
GC-tracked bytes per operation for the specified 1 KiB record, not native memory.

## Validation

The final modified core passed **557 examples**, and the paired local Pro
worktree passed **414 examples**, both with zero failures/errors/pending and six
configured workers against owned Redis 8.0.2 URL/TLS fixtures. Added regressions
cover compact acknowledgment fields, heavily escaped/Unicode payloads, duplicate
admissions after completion, and checksum compatibility/rejection. Existing
ownership, cancellation, corruption, telemetry and partial-write cases pass.

Batch-size-eight process faults conserved 20/20 completions and distinct effects
after SIGKILL (28 attempts), and 8/8 after SIGTERM (16 attempts; approximately
114 ms bounded incomplete drain). Replacement workers drained cleanly on SIGINT.
Formatting and whitespace checks passed. These changes remain uncommitted;
hosted CI and a new remote Pro dependency pin have not been validated.
