# Implementation validation — 2026-10-29

Core baseline: `8310229` (PR #19 merged with `a9d9618`). Pro baseline: `f2b6d73`. Results below cover the subsequent hardening changes in this review commit. Local dependency symlinks point to the installed versions in `shard.lock`; Pro's core link points to this worktree. These are local results, not hosted CI evidence or a clean-install certification.

Environment: Crystal 1.22.1, Redis 8.0.2, Linux. The integration harness owns all Redis processes, temporary AOF directories and TLS certificates. AOF `appendfsync always` is enabled. The harness rejects missing/skipped examples and detected background runtime crashes.

| Check | Result |
| --- | --- |
| Core full suite, 4 workers, legacy host/port config | 520 examples, 0 failures/errors/pending |
| Core full suite, 1 worker, URL config | 520 examples, 0 failures/errors/pending |
| Pro full suite, 4 workers, paired core | 404 examples, 0 failures/errors/pending |
| Delivery, bare-thread finalizer and pipeline focused regressions | 10 examples passed before the final full suite |
| Redis SIGKILL / AOF restart | 990 queued + 10 claimed legacy payloads conserved; 100 canonical ledger records conserved; 20 expired leases recovered |
| Crystal formatting, Python syntax, git whitespace | Passed |

Commands, from core after activating the compiler/toolchain:

```sh
CRYSTAL_WORKERS=4 python3 scripts/run_integration.py
CRYSTAL_WORKERS=1 python3 scripts/run_integration.py --url
python3 scripts/redis_restart_smoke.py
crystal tool format --check src spec
```

From Pro, use `python3 lib/joobq/scripts/run_integration.py` with the same worker/profile options.

An earlier 511-example URL run printed a Crystal execution-context monitor crash despite reporting zero spec failures. That run is not clean validation. The Redis finalizer override and harness crash rejection were added, and the final 520-example URL run completed without that diagnostic.

Not proven: all four worker/connection combinations locally, Redis 7.4, clean remote paired dependency resolution, hosted CI, arbitrary partial-state faults, disk loss/failover, lease-aware production workers, migration/restore, 35k settled jobs/sec or the four-hour soak. See implementation-status.md for the remaining release gates. No version bump or release authorization is inferred from these tests.
