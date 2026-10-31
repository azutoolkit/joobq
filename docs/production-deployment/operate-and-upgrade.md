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
3. Account for open runs before replacement. Drain them or verify the replacement can execute their remaining steps, and retain the compatible binaries needed for recovery. A stored definition does not preserve an old executable implementation by itself.
4. For the default legacy transport, quiesce and stop old consumers with the tested grace period before replacement: startup recovery can reclaim another process's active work. Use overlapping rollouts only after validating the chosen transport and recovery policy.
5. Start compatible replacement workers, complete a canary, and reconcile abandoned or uncertain work before reopening admission.

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

For a pre-promotion canary, pass `build: "orders-2026-10-30"` to `Client#start`; otherwise the run uses the currently promoted default and may test old workers instead. Use a safe canary input and check its result.

Build isolation is not universal: workers with build IDs also consume the shared activity queue, and compensations are dispatched there. Keep compensation handlers compatible across those workers. See the [legacy recovery limit](../best-practices/recovery.md#know-the-legacy-startup-recovery-limit) before overlapping processes.

Promotion controls new-run routing; it is not a rollback of external effects. Do not declare builds compatible unless old inputs and behavior actually remain compatible. Keep a rollback boundary for state written by new code.

Configure management tokens only if the API is enabled, keep access private, and test credential rotation with your actual clients. See [management access](../configuration/access.md). Replay one reviewed failure at a time before expanding a recovery operation.

**Next:** [Test workflows](../guides/test-workflows.md) and [capacity planning](../best-practices/performance.md).
