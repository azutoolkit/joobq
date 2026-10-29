# Local validation evidence — 2026-10-29

## Scope and environment

- Audited baseline: JoobQ `b38961d`; JoobQ Pro `5f68249`.
- Worktrees: `/workspace/scratch/joobq-v1-audit` and `/workspace/scratch/joobq-pro-v1-audit`, each on `codex/v1-reliability-audit`.
- Crystal 1.22.1 / LLVM 22.1.3; Redis 8.0.2 on Linux.
- Redis 2.9.1, pool 0.2.4, cron_parser 0.4.0; installed dependency directories were reused via worktree symlinks. Pro's `lib/joobq` points to the patched core worktree. This is not evidence of a newly published shard graph.
- Isolated Redis servers at 127.0.0.1:16479 (core) and :16480 (Pro/optional second-store test), separate `/tmp/joobq*-v1-redis` data directories, AOF enabled, `appendfsync=always`, DEBUG allowed for the existing reload spec. Shared workspace Redis/PostgreSQL were not reset.
- The standalone restart harness allocates its own port, temporary data directory and Redis process, and cleans them up. It never accepts a live Redis address.

## Before/after evidence

New core regression spec against unchanged baseline implementation: **3 examples, 3 failures**:

1. Wrong-type delayed destination: the delayed source member disappeared.
2. Wrong-type DLQ: the processing list became empty despite DLQ write failure.
3. Batch capacity 2, 20 blocked jobs: queue depth became 0 instead of 18.

New Pro regression against unchanged implementation: **1 example, 1 failure**. Failed activity dispatch left a second history event (StepScheduled), when the history should still contain only WorkflowStarted.

Those initial regressions all passed with the patches. Additional core checks cover retained malformed payloads after failed DLQ writes, simultaneous delayed promoters, preservation of Int64::MAX, bounded stalled-command failure followed by reconnect, and structured JSON log fields.

## Suite results

| Run | Result | Notes |
| --- | --- | --- |
| Pro full suite, CRYSTAL_WORKERS=2 | 398 examples; 0 failures/errors/pending | Patched core + workflow preflight. |
| Pro full suite, CRYSTAL_WORKERS=4 | 398 examples; 0 failures/errors/pending | Includes Pro structured-log metadata patch. |
| Core full suite, CRYSTAL_WORKERS=4, final verified rerun | 437 examples; 0 failures/errors; 4 pending | Includes all code and regression specs. |
| Core full suite, CRYSTAL_WORKERS=1, second Redis enabled | 437 examples; 0 failures/errors; 3 pending | Separate-store characterization passed; three explicitly pending examples remain. |
| Owned Redis SIGKILL/AOF restart | PASS | Exactly 990 ready + 10 claimed payloads, IDs 0..999, preserved. |
| Crystal format and git whitespace checks | PASS | Both repositories. |

The four pending core examples were:

- `Race Conditions concurrent job enqueue handles multiple concurrent enqueues` — explicitly pending in the existing suite.
- `store wiring ... DeadLetterQueue.new and WorkerRegistry.new follow the ENV instance, not config.store` — optional second Redis was initially unset. This characterization test exposes an existing integration mismatch; it does not certify that mismatch as desirable behavior.
- `JoobQ::Queue(T) #start processes enqueued jobs` — explicitly pending in the existing suite.
- `Retry Refactor DelayedJobScheduler processes due delayed jobs automatically` — explicitly pending in the existing suite.

Earlier full-suite runs were not all green: the first found a legacy return-value contract regression in delayed processing (fixed by preserving all-scanned return behavior), and a new timeout assertion expected the wrong exception subclass. Redis 2.9.1 actually wraps the socket timeout as ConnectionLostError and retries once. A subsequent run failed the API listener readiness test, which swallowed its startup exception and chose a random fixed-range port. The test now obtains an available port from the OS and reports startup exceptions; the next full run passed. The original listener failure's precise cause was not captured.

## Reproduction

With dependencies installed and **dedicated disposable Redis servers** (core spec setup uses FLUSHDB):

```sh
REDIS_HOST=127.0.0.1 REDIS_PORT=16479 CRYSTAL_WORKERS=4 crystal spec
REDIS_HOST=127.0.0.1 REDIS_PORT=16479 JOOBQ_SPEC_SECOND_REDIS_PORT=16480 CRYSTAL_WORKERS=1 crystal spec
python3 scripts/redis_restart_smoke.py
crystal tool format --check src spec
```

Run Pro's suite from its own repository against a separate disposable Redis. Use separate `CRYSTAL_CACHE_DIR` values if compiling/running both suites concurrently. In this workspace the compiler/tools are on PATH after `source /workspace/setup/env.sh`.

## What these tests do not establish

- No ≥35k completed/settled jobs/sec measurement or long-running soak was performed. The restart harness's enqueue timing is not throughput acceptance evidence.
- No replica promotion, Sentinel/Cluster support, storage/device loss, backup restore, TLS verification or credential rotation was validated.
- Retaining processing payloads does not prove continuous crash recovery; distributed leases are still missing.
- No guarantee of exactly-once external effects; no general Lua rollback guarantee.
- Pro WebSocket connection/disconnection behavior was not exercised end to end; core JSON formatting has a regression test.
- No live application deployment inspection and no hosted Actions result. Core CI now contains the restart probe, but hosted execution and dependency resolution remain release gates.
- Local Redis was 8.0.2; the pinned core CI service is 7.4. Both must be checked in the supported-version matrix before release.
