---
description: Monitor completed work and deploy changes without abandoning old runs.
---

# Operate and upgrade

Measure the outcome your users need. “The worker is running” is useful, but “orders complete within their latency objective” is the better signal.

## Watch the right signals

| Signal | What it helps explain |
| --- | --- |
| Age of oldest waiting work | Whether the backlog is becoming a user-facing delay |
| Completed jobs or workflows per interval | Useful throughput, separate from admissions and attempts |
| End-to-end p50/p95/p99 | Queue wait plus processing time |
| Retries, failures, DLQ growth | Dependency failures, input problems, or exhausted recovery |
| Worker heartbeats and busy capacity | Actual consumers, distinct from Redis connectivity |
| Redis latency, memory, disk, and persistence health | Storage pressure and durability risks |
| Compensation failures and unresolved outcomes | Work that needs human reconciliation |

Use the [available metrics and logging interfaces](../pro/observability.md). Not every signal is exposed automatically in every baseline: calculate business completion and queue-age metrics where needed. A “connected” indicator is not worker-health evidence. Redact credentials, payload secrets, and personal data before exporting logs.

## Deploy compatible changes

1. Pin and build the dependency graph. Keep a copy of the previous binary and configuration.
2. Test old serialized inputs against new handlers. Preserve activity aliases and compare definition hashes when translating constructors to the DSL.
3. Start compatible workers before admitting work that needs their handlers. Use a small canary and observe completion.
4. Keep workers needed by open runs until they drain. A stored definition does not preserve an old executable implementation by itself.
5. Stop replaced workers with the tested grace period. Reconcile abandoned or uncertain work before removing old capacity.

For applications already using Pro build pinning, these are the existing APIs—not a new deployment service:

In your worker entry point, supply its build ID when constructing the worker; keep the registration, signal handling, and shutdown lifecycle:

<!-- illustrative: worker construction within the production entry point -->
```crystal
worker = JoobQPro::Workflows::Worker.new(
  activity_workers: 2, orchestrators: 1, scheduler: false,
  build_id: "orders-2026-10-30")
```

After those workers pass your canary, promote from a separate operator process configured for the same store:

<!-- illustrative: reviewed promotion after the application's canary passes -->
```crystal
client = JoobQPro::Workflows::Client.new
client.promote_build("orders", "orders-2026-10-30")
```

Promotion controls new-run routing; it is not a rollback of external effects. Do not declare builds compatible unless old inputs and behavior actually remain compatible. Keep a rollback boundary for state written by new code.

Configure management tokens only if the API is enabled, keep access private, and test credential rotation with your actual clients. See [management access](../configuration/access.md). Replay one reviewed failure at a time before expanding a recovery operation.

**Next:** [Test workflows](../guides/test-workflows.md) and [capacity planning](../best-practices/performance.md).
