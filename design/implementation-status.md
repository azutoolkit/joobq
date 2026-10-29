# Enterprise v1 implementation status

This records implemented changes separately from the historical audit and acceptance criteria. The full enterprise-v1 plan remains open; version numbers remain pre-v1.

## Implemented foundation

- PR #19 (`498ac5f`) integrated with the audited master fixes in merge `8310229`; URL/TLS/ACL and strict enqueue behavior preserved.
- Disposable integration harness creates plain, second-store and verified TLS fixtures; rejects pending tests and runtime/fiber crashes. Three formerly pending core cases now run.
- Legacy and URL Redis constructors share the authenticated, credential-redacted client and finite connect/command timeouts. Lost responses raise `RedisOutcomeUnknown` without automatic mutation replay. These are per-phase timeouts, not a total operation deadline.
- Real pipeline batching uses one connection, propagates errors and discards sockets with unread replies. Pipeline stats are synchronized. Legacy cleanup/read helpers no longer turn Redis failures into apparent success.
- Explicit queue store/execution binding allows Pro activities to retain their worker's history store. DLQ calls use the queue's store; failed DLQ settlement propagates.
- A dependency compatibility fix leaves garbage-collection resource release to stdlib socket/SSL finalizers. The Redis dependency previously invoked buffered socket close on Crystal's monitor thread, crashing it despite a green spec summary. A bare-thread regression and harness crash detection cover that failure.
- Experimental delivery ledger: stable request identity, Accepted/Rejected/Unknown admission, opaque payloads, canonical CAS transitions, server-time leases, fencing, idempotent terminal outcomes and derived-index repair. See [prototype limits](delivery-prototype.md).
- Pro: atomic Redis-time rate admission before execution, non-failure deferral, explicit workflow transport/history binding, and fiber-local nested batch scope. Full batches/uniqueness and workflow recovery remain open.

## Package status

P00–P03 are partially implemented. P01's protocol has executable fault regressions; this does not complete all architecture/SLO decisions. P04–P06 have a separate storage prototype, not production worker integration. P09/P11 have targeted concurrency fixes, not complete enterprise feature acceptance.

Still required: independently scoped runtime registries; total transport deadlines, circuit breaking and close/drain; leased worker integration and reconciliation; admission/retention budgets; atomic Pro batches/callback outbox and uniqueness; observability/authentication; migration/restore; Redis 7.4/8.0 matrix; multi-process chaos; 35k settled jobs/s reference benchmark; four-hour soak; exact-SHA hosted CI and release review. Full acceptance criteria remain in [enterprise-v1-plan.md](enterprise-v1-plan.md).

Validation results for this implementation are recorded in [implementation-validation.md](implementation-validation.md). Passing examples are evidence for the named cases only, not a claim of HA or exactly-once external effects.
