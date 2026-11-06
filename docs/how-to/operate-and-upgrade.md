---
description: Monitor completed work and deploy changes without abandoning old runs.
---

# Operate and upgrade

*How-to · Core · Pro*

## Prerequisites

- The worker binary built from a committed `shard.lock`, and the previous binary and configuration kept for rollback.

## Watch the right signals

Alert on these, from `/metrics`, your logs or your own counters:

| Signal | What it shows |
| --- | --- |
| Age of oldest waiting work | Whether the backlog is becoming a user-facing delay |
| Completed jobs or workflows per interval | Useful throughput, separate from admissions and attempts |
| End-to-end p50/p95/p99 | Queue wait plus processing time |
| Retries, failures, DLQ growth | Dependency failures, input problems, or exhausted recovery |
| Worker heartbeats and busy capacity | Actual consumers, distinct from Redis connectivity |
| Redis latency, memory, disk, and persistence health | Storage pressure and durability risks |
| Compensation failures and unresolved outcomes | Work that needs human reconciliation |

## Deploy a change

1. Test old serialized job inputs against the new handlers, and for workflows compare definition hashes.
2. Drain open workflow runs, or check that the new workers can run their remaining steps; keep the old binaries until they finish.
3. Stop old Core consumers with their full grace period before starting new ones.
4. Start the new workers, complete a canary job or run, and reconcile any work left uncertain before you reopen admission.

## Roll out a Pro build

1. Start the new workers with their build id:

<!-- illustrative: worker construction within the production entry point -->
```crystal
worker = JoobQPro::Workflows::Worker.new(
  activity_workers: 2, orchestrators: 1, scheduler: false,
  build_id: "orders-2026-10-30")
```
2. Start a canary run on that build with `client.start(..., build: "orders-2026-10-30")`, using a safe input, and check its result.
3. Promote the build from an operator process configured for the same store:

<!-- illustrative: reviewed promotion after the application's canary passes -->
```crystal
client = JoobQPro::Workflows::Client.new
client.promote_build("orders", "orders-2026-10-30")
```
Workers with build ids still take compensations from the shared activity queue, so keep compensation handlers compatible across builds.

## Verify

- The canary completed on the new build, and the signals above stayed within their thresholds.
- `client.build_ids` lists the new build as the default.

## See also

- [Roll out worker builds](https://joobq-website.onrender.com/docs/how-to/zero-downtime-worker-builds): the console's build pages.
- [Reliability and recovery](../explanation/reliability-and-recovery.md)
