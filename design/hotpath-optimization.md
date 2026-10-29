# Delivery hot-path optimization — 2026-10-29

The optimized ledger performs normal admission, claim, renewal and settlement
in one Redis script round trip each. The previous client-side read/modify/CAS
sequences caused repeated reads and competing writes when many workers selected
the same first ready record. Atomic claim selection removes that contention.
Scripts are cached with EVALSHA; only a confirmed NOSCRIPT permits an EVAL retry.

A runtime-wide scanner replaces the per-job renewal fiber and two channels.
Only leases reaching renewal time create a renewal operation. Per-lease mutexes
serialize renewals with settlement, without holding the registry lock across I/O.
Worker slots still follow actual execution lifetime, including incomplete drain.
This keeps concurrency bounded by configured execution capacity.

Payloads remain opaque strings, and metadata outside the Lua encoder's exact
integer range falls back to the Crystal Int64 CAS path. Checksums are validated
before execution. Corrupt claims restore/quarantine original bytes with an
ownership guard. Canonical writes still precede derived indexes, preserving
Unknown-outcome and repair behavior. Details are in [ADR 001](adr/001-delivery-contract.md).

## Repeated comparison

Three repetitions per profile, 10,000 jobs per run, Crystal 1.22.1 / Redis 8.0.2,
1 KiB payloads, verified TLS, AOF `appendfsync always`. All 150,000 accepted IDs
completed. Runs were sequential; producers and workers within each run were
concurrent. Both protocols used the current renewal scanner and the same release
binary. End-to-end time includes receipt reconciliation. Values below are medians
of the per-run rate, admission p99 and allocated bytes/job.

| Protocol | Execution threads | Producers / slots | Completed/s | Admission p99 | Allocated/job |
| --- | ---: | ---: | ---: | ---: | ---: |
| CAS | 4 | 16 / 16 | 1,298 | 5.11 ms | 188,559 B |
| Atomic | 4 | 16 / 16 | **4,051** | **2.92 ms** | **24,804 B** |
| Atomic | 1 | 16 / 16 | 3,948 | 4.46 ms | 24,731 B |
| Atomic | 4 | 32 / 32 | 3,775 | 5.15 ms | 26,264 B |
| Atomic | 8 | 32 / 32 | 3,820 | 5.06 ms | 26,181 B |

At equal concurrency the atomic path was **3.12× faster**, used **86.85% less
allocation**, and reduced admission p99 by **42.77%**. Increasing concurrency
beyond 16 slots did not improve throughput on this host/Redis configuration.
These results are not a universal concurrency recommendation. Application handlers,
network distance, storage and payload size will change the optimum.

[Raw runs](evidence/hotpath-comparison-2026-10-29.json) retain every measurement.
The earlier unoptimized results remain in implementation-validation.md; these new
measurements supersede their performance numbers, not their fault evidence.

## Scope and limitations

This is an optimization of the existing schema-1 protocol, not a new data format.
`Runtime.new(..., optimized_delivery: false)` selects the CAS path for diagnostics;
atomic and CAS clients can coexist against the same canonical records. Set
`BENCH_PROTOCOL=cas|atomic` or use `scripts/benchmark_delivery.py` to reproduce.

The implementation allocates; it does not claim zero-allocation operation. The
35,000 completed/s gate remains **unmet**, and seconds-long runs cannot certify
the 30-minute target or four-hour soak. No TLS/fsync setting or receipt check was
weakened. Terminal retention/compaction remains a separate release blocker.

## Correctness validation

The optimized implementation passed 542 core examples on Redis 8.0.6 and 414
paired Pro examples on Redis 8.0.2, both with four execution threads and URL
configuration. Subsequent dispatch-boundary/integrity regressions passed 12
examples. The dispatch counter now uses UInt64 rather than failing at the signed
32-bit boundary. Worker SIGKILL/signal probes and a new 60-second Redis-pause
smoke conserved all accepted jobs and distinct effects. See the
[validation manifest](evidence/hotpath-validation-2026-10-29.json).

Hosted CI exposed and prompted two fixes before this optimization: concurrent
recursive Redis fixture builds raced on dependency archives, and kernel TLS
required a native Socket beneath the SSL layer. The installer now uses one make
invocation, and deadline-enforcing Socket subclasses preserve OpenSSL's BIO
contract. Certificate/hostname verification remains enabled. The reviewed SHA
must pass hosted CI; earlier failing runs do not constitute certification.
