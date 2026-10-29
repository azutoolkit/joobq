# Delivery validation workloads

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
