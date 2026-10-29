# Delivery validation workloads

Allocation measurements and reproduction instructions are in the
[delivery allocation report](../design/delivery-allocation-optimization.md).
`crystal run benchmarks/allocations.cr --release` isolates JSON encoding and
checksum-validation allocations; it does not run a Redis workload.

Run only through `scripts/run_integration.py --probe`: it creates and cleans up
its own plain/second/TLS Redis processes with AOF `always`. Probes require the
fixture-specific TLS URL/CA and do not use the operator's Redis address.

```sh
crystal build benchmarks/leased.cr --release -o /tmp/joobq-leased
BENCH_JOBS=10000 BENCH_PRODUCERS=16 CRYSTAL_WORKERS=4 \
  python3 scripts/run_integration.py --probe /tmp/joobq-leased
crystal build benchmarks/soak.cr --release -o /tmp/joobq-soak
SOAK_SECONDS=60 SOAK_RATE=50 CRYSTAL_WORKERS=4 \
  python3 scripts/run_integration.py --probe /tmp/joobq-soak
python3 scripts/run_integration.py --probe python3 scripts/leased_process_probe.py
```

`leased.cr` reconciles every accepted identity to Completed. Its elapsed time
includes admission and reconciliation, so the reported rate is conservative
end-to-end confirmed throughput. It is not an enqueue-only or attempt count.
Reports include TLS, fsync, payload size, workers, producer concurrency, admission
p50/p99, GC and whether the throughput/duration targets were met. A normal process
exit establishes conservation, **not** the 35k/s or 30-minute acceptance gate;
check the explicit booleans. The current finite benchmark is a diagnostic and
cannot certify the sustained reference gate. The handler has no business work.

`soak.cr` uses 1 KiB payloads, paced admission, stable idempotent effect receipts,
one-second leases and periodic 500 ms Redis pauses against 200 ms operation
deadlines. Unknown admissions retry the same identity. It checks every completion
and distinct effect, then drains. Its report records actual elapsed time and
whether four hours were reached. A 60-second pass is a smoke test. Pauses are not
Redis process death: the separate process probe covers worker SIGKILL and signal
drain; `redis_restart_smoke.py` covers server SIGKILL/AOF recovery.

The soak rejects a planned count above `SOAK_MAX_RECORDS` (default 100,000).
No receipts are deleted to make a test pass. For a longer controlled run set a
capacity and Redis memory/disk budget sufficient for **all retained receipts**,
then set `SOAK_SECONDS`, `SOAK_RATE` and the harness `--timeout`. The four-hour
plan calls for 60% of measured sustainable throughput, not an arbitrary low rate.
A long run at 50/s does not satisfy that gate. Retention/compaction is a known
blocker for the full reference workload on this environment.

Evidence is in `design/implementation-validation.md`. Do not weaken TLS, fsync,
receipt conservation or the requested duration to report a passing v1 target.

## Repeated concurrency comparison

```sh
crystal build benchmarks/leased.cr --release -o /tmp/joobq-leased
python3 scripts/benchmark_delivery.py --binary /tmp/joobq-leased \
  --jobs 10000 --repeats 3 --output /tmp/delivery-comparison.json
```

The same executable supports `BENCH_PROTOCOL=cas` or `atomic`; only ledger
operation strategy changes. Capacity, payload, TLS, fsync and per-ID conservation
remain the same. The report includes median rates, admission p99 and allocated
bytes per job, plus every raw run. Both strategies use the current renewal
scanner, so this comparison isolates the ledger optimization. Earlier evidence
retains the pre-optimization runtime measurements.

To size execution threads to the machine's visible CPUs on Linux:

```sh
CRYSTAL_WORKERS=$(nproc) python3 scripts/benchmark_delivery.py \
  --binary /tmp/joobq-leased --jobs 10000 --repeats 3 \
  --output /tmp/delivery-cpu-sized.json
```

The runner honors `CRYSTAL_WORKERS` and uses atomic delivery with 16 producers
and 16 job slots. Explicit `--workers 1 4 5 6` overrides the environment variable
and compares those thread counts at identical concurrency. Without either setting,
the original five-profile CAS/atomic comparison runs. Execution threads and job
slots are separate: asynchronous I/O permits more active jobs than CPU threads.
The benchmark explicitly resizes Crystal's default execution context to the
requested thread count. Each run gets an isolated Redis fixture; runs are sequential
to avoid competing benchmarks.

Check the container CPU quota as well as `nproc`: visible CPUs may exceed its
allowed CPU time. The JSON report records CPU visibility, affinity, and Linux
cgroup v2 `cpu.max` when available. Redis shares this host's CPU budget, so compare
measured rates before choosing a production worker count.

## One million no-op jobs

`leased.cr` also supports `BENCH_BATCH_SIZE=1..128` (default 1) and
`BENCH_PAYLOAD_BYTES=1..16384` (default 1024). Batched latency is the time to
confirm the entire admission batch, assigned to every member; it is not divided
by batch size. The no-op handler counts actual executions, and every final
receipt must have attempt 1. Batch size must not exceed `BENCH_CAPACITY`.

For the same-host, two-partition, one-million-job acceptance run:

```sh
crystal build benchmarks/leased.cr --release -o /tmp/joobq-leased
CRYSTAL_WORKERS=2 python3 scripts/benchmark_million.py \
  --binary /tmp/joobq-leased --partitions 2 --payload-bytes 64 \
  --output /tmp/million.json --require-target
```

This uses two independent Redis primaries and runtime processes on the current
host. Both retain verified TLS, AOF `always`, and all completion receipts.
Aggregate elapsed time includes fixture startup/cleanup. See the
[implementation, topology and limits](../design/million-per-minute.md).
The 1 KiB configuration uses `--partitions 3 --payload-bytes 1024`;
two partitions narrowly missed the strict 60-second gate at that payload size.

## Existing Queue, Worker and Scheduler

`legacy.cr` measures three separate operations through the list-based API:
`BENCH_MODE=queue` admits typed JSON batches, `worker` executes and settles jobs,
and `scheduler` promotes due jobs. `BENCH_JOBS` defaults to 10,000 (maximum 100,000).
The 1 KiB payload is fixed; worker and admission batch sizes are 128 and 100.
Each run verifies all job indexes and payloads; worker mode counts actual handler
executions and waits for processing/tracking to drain.

```sh
crystal build benchmarks/legacy.cr --release -o /tmp/joobq-legacy
CRYSTAL_WORKERS=4 BENCH_JOBS=30000 BENCH_MODE=worker \
  python3 scripts/run_integration.py --probe /tmp/joobq-legacy
```

Use an owned fixture for every run. Compare the same mode, logging settings and
thread count across builds, with no competing tests or compilers. Reported bytes
are cumulative GC allocations per operation, not peak RSS. Admission/promotion
rates must not be presented as completed-job rates. See the
[comparison, validation and limits](../design/legacy-hotpath-optimization.md).
