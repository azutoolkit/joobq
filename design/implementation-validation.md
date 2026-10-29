# Implementation validation — 2026-10-29

The implementation continues core `0e35f14` (which incorporates PR #19) and Pro
`0f14a51`. These results cover the subsequent working-tree hardening changes
submitted with this report. They are local results, not hosted CI certification.
Local dependencies match the lock files; Pro used the paired core worktree.

Environment: Linux, Crystal 1.22.1, four execution workers unless stated,
Redis 8.0.2 (jemalloc) and Redis 7.4.12 (libc, checksum-pinned source build).
The harness owns every Redis process, AOF directory and test certificate. It
rejects skipped examples and detected background runtime crashes. Redis uses
AOF `appendfsync always`; TLS cases verify the generated CA and hostname.

| Check | Observed result |
| --- | --- |
| Core full suite, Redis 8.0.2, 4 workers, legacy configuration | 537 examples, 0 failures/errors/pending |
| Core full suite, Redis 7.4.12, 1 worker, URL configuration | 537 examples, 0 failures/errors/pending |
| Pro full suite, Redis 8.0.2, 4 workers, legacy configuration | 414 examples, 0 failures/errors/pending |
| Pro full suite, Redis 7.4.12, 1 worker, URL configuration | 414 examples, 0 failures/errors/pending |
| Worker SIGKILL, replacement process, TLS | 20 accepted/completed/distinct effects; 21 attempts |
| Worker SIGTERM during execution, replacement process, TLS | 1 accepted/completed/distinct effect; 2 attempts; bounded incomplete drain about 114 ms |
| Replacement worker SIGINT | Clean drain and exit in both process-fault scenarios |
| Fault soak smoke, TLS/AOF-always, 1 KiB, 50/s | 60.16 seconds, 3,000 accepted/completed/distinct effects; 3,001 attempts; 5 Redis pauses |
| Deadline, migration/restore, poison repair, telemetry and typed execution | Included in full suites |
| Crystal formatting, Python syntax, workflow YAML parsing, git whitespace | Passed |

The fault soak produced 10 unknown admissions and one unknown settlement;
identity-safe replay and lease repair conserved all accepted jobs. It retained
all 3,000 receipts and ended with zero pending or leased entries. This is a
**60-second smoke test**, not the required four-hour soak. Tests of namespace
restore compare receipts on an independent Redis; they do not measure an actual
application's RPO/RTO or external data consistency.

## Load evidence and failed acceptance gate

Two earlier diagnostic runs completed all IDs:

- 5,000 jobs, one producer: 1,651.02 confirmed completions/s, admission p99 1.50 ms.
- 10,000 jobs, 16 producers: 1,397.07/s, admission p99 4.57 ms.

The final-code rerun completed 10,000/10,000 jobs at **1,375.08/s**, admission
p99 **5.29 ms**, in 7.27 seconds.

All used 1 KiB payloads, TLS, AOF-always, capacity 16 and four Crystal workers.
They ran for seconds, not 30 minutes. The 35,000 settled-jobs/s gate **failed**;
no configuration was weakened to obscure that result. Reconciliation is included
in elapsed time. A final-code rerun and the smoke/process manifests are recorded
in [machine-readable evidence](evidence/local-delivery-2026-10-29.json).

The protocol currently performs multiple reads/CAS/JSON rewrites per job and
retains terminal receipts. Profile server/client CPU, allocation and claim
contention before choosing a bounded batch protocol. Preserve opaque payloads,
large integers, ambiguous-result resolution and canonical-state-first recovery
when optimizing; an enqueue-only benchmark is not an acceptable replacement.

## Reproduction

```sh
CRYSTAL_WORKERS=4 python3 scripts/run_integration.py
CRYSTAL_WORKERS=1 python3 scripts/run_integration.py --url
python3 scripts/run_integration.py --probe python3 scripts/leased_process_probe.py
crystal tool format --check src spec benchmarks
```

Use Pro's `python3 lib/joobq/scripts/run_integration.py` for its suite.
`python3 scripts/install_test_redis.py 7.4.12 /tmp/test-redis` builds a pinned
server/CLI; prepend `/tmp/test-redis/bin` to PATH to select it. CI covers Redis
7.4.12/8.0.6 × workers 1/4 × legacy/URL, and runs the worker-fault and short soak
probes in the four-worker URL lanes. Load/soak instructions are in
[benchmarks/README.md](../benchmarks/README.md).

## Unmet release gates

The 30-minute 35k reference workload, four-hour soak at 60% measured sustainable
throughput, receipt archival/retention, wider workflow-history partial-write and
multi-process Pro failure coverage, deployment TLS/proxy/failover validation,
credential rotation and measured restore objectives remain open. Hosted CI must
pass the reviewed paired SHAs. The legacy management API does not yet manage
runtime-scoped queues. No v1 version bump, merge, zero-loss or exactly-once
external-effects assertion follows from these results.
