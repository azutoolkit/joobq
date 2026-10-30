---
description: Recover deliberately when processes, networks, or storage fail.
---

# Recovery and migration

Define two goals before choosing Redis persistence: how much acknowledged work may be lost (RPO), and how long recovery may take (RTO). A “zero data loss” requirement needs a tested storage and failover design, not just successful enqueue responses.

## Recovery checklist

1. Preserve logs, queue names, job/receipt identifiers, deployment revisions, and timestamps. Redact payloads and credentials.
2. Identify whether work uses legacy queues, Delivery, or Pro workflows. Their state and recovery paths differ.
3. Determine whether the external effect already happened before replaying.
4. Restore connectivity or storage into an isolated environment first when corruption or rollback is suspected.
5. Inspect pending, processing, delayed, and dead-letter state. For Delivery, include leases, receipts, and reconciliation journals.
6. Replay a selected item after reviewing its identity and idempotency behavior. Monitor before expanding recovery.
7. Record unresolved outcomes and follow up; an empty ready queue alone is not proof of completion.

## Rehearse these failures

| Failure | What to verify |
| --- | --- |
| SIGTERM during a handler | Drain budget, exit status, unfinished work and external effects |
| Forced worker exit | Recovery of processing work and duplicate-safe effects |
| Redis restart or partition | Bounded failures, reconnection, unknown admission outcomes |
| Lost acknowledgment | Reconciliation using the same identity, without blind duplication |
| Redis restore | Missing/newer work, receipt retention, replay policy and measured RPO/RTO |
| Pro reconciler interruption | Batch dispatch, callback dispatch and workflow progress recover |

## Migrate a processing API separately from an upgrade

A dependency upgrade does not move legacy `Job.enqueue` work into Delivery. Use separate namespaces and an explicit cutover plan. Stop or redirect producers, drain or account for old work, validate the new path with a small workload, and retain old state long enough to reconcile.

Document the rollback boundary. A new consumer may write state an old release cannot read. Do not start old binaries against that state until you have tested compatibility. Never delete queue keys or journals merely to make a deployment look healthy.

For Pro, retain the compatible Core revision from its lockfile. See [compatibility](../introduction/compatibility.md) and the [Delivery preview](../core/delivery.md).
