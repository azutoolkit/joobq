# Enterprise v1 implementation status

The work builds on PR #19 and the foundation in `0e35f14`. Version numbers remain
pre-v1. Implementation and bounded test evidence do not certify the complete
[enterprise-v1 plan](enterprise-v1-plan.md).

## Implemented for review

- Atomic Redis hot paths with cached scripts, exact-integer fallback and lazy
  renewal scheduling; [repeated concurrency results](hotpath-optimization.md).
- Runtime-scoped queue registry, fixed execution capacity, renewable fenced
  leases, cooperative execution deadline, supervised worker/repair loops, local
  circuit breaker and bounded signal drain. Typed jobs and explicit raw handlers.
- Total Redis deadlines across checkout/connect/TLS/setup/command, verified TLS,
  failure eviction and no automatic replay of ambiguous mutations. Foundation
  pipeline/finalizer fixes remain covered.
- Stable admission IDs, canonical CAS state, bounded retained-record admission,
  index repair and poison preservation/quarantine. Generic durable CAS journals.
- Pro sealed batch membership, replayable member/callback outboxes, counts from
  terminal receipts, owner-fenced uniqueness and workflow dispatch-list bridging.
- Bounded OTLP telemetry with linked producer/consumer spans, Prometheus text,
  authenticated legacy management API, role/body limits and loopback binding.
- Quiescent migration with verification and explicit activation; namespace
  export/digest/restore with original-source preservation and resume checks.
- Owned Redis/TLS harness, process-death and signal probes, completion-counting
  load benchmark, pinned Redis 7.4/8.0 CI matrix.

Read [API and operations instructions](durable-runtime-guide.md), particularly
legacy compatibility, capacity and backup limitations. Pro's public batch and
unique APIs now require explicit durable services. Legacy queues and middleware
are still available and do not silently acquire the new delivery guarantees.

## Release blockers still open

- Measured completion throughput is far below 35k/s; 30-minute reference workload
  and four-hour fault soak have not passed. The optimized path improves the equal-concurrency median from 1,298 to 4,051/s
  but does not meet the required rate/duration.
- Retained terminal receipts and journals have finite admission budgets but no
  safe archival/compaction policy. Size, retention horizon and sustained workload
  admission must be solved together before long-running production certification.
- Broader workflow-history partial-write fault coverage, durable recurring
  scheduling, multi-process batch/unique crash validation, deployment failover,
  restore RPO/RTO and credential rotation need further acceptance evidence.
- Full namespace-scoped management HTTP integration, latency histograms and
  production alerts/dashboards remain open.
- Hosted CI must pass the reviewed paired commit; neither PR may infer release
  authorization or a version bump from local tests.

[Validation](implementation-validation.md) distinguishes exact observed results
from planned acceptance gates. No exactly-once external-effects or unconditional
zero-loss claim is made.
