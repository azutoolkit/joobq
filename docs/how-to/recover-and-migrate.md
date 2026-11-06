---
description: Recover deliberately when processes, networks, or storage fail.
---

# Recover and migrate

*How-to · Core · Pro*

## Prerequisites

- Access to the Redis the work lives in, and the logs and deployment revisions of the incident window.

## Recover after an incident

1. Keep the evidence: logs, queue names, job and run ids, deployment revisions, timestamps. Redact payloads and credentials.
2. Find out which path the work used: Core queues, Delivery or Pro workflows.
3. For each job you might replay, check whether its external effect already happened.
4. If you suspect corruption or a bad rollback, restore into an isolated environment first.
5. Inspect waiting, processing (`joobq:processing:<queue>`), delayed and dead-letter state; for Delivery also leases and receipts.
6. Replay one reviewed job, watch it, then the rest. Record every outcome you could not resolve.
7. Before you start consumers again after a crash, quiesce them: a restarting queue moves only one job back from its processing list.

## Migrate to another processing path

1. Use a separate namespace for the new path (for example a new Delivery runtime namespace).
2. Stop or redirect producers, then drain or account for the old work.
3. Validate the new path with a small workload, keeping the old state until it is reconciled.
4. Write down the rollback boundary: do not start old binaries against state written by the new release until you have tested that they can read it.

## Rehearse failures

In staging, cause each failure below and check what the second column names:

| Failure | What to verify |
| --- | --- |
| SIGTERM during a handler | Drain budget, exit status, unfinished work and external effects |
| Forced worker exit | Recovery of processing work and duplicate-safe effects |
| Redis restart or partition | Bounded failures, reconnection, unknown admission outcomes |
| Lost acknowledgment | Reconciliation using the same identity, without blind duplication |
| Redis restore | Missing/newer work, receipt retention, replay policy and measured RPO/RTO |
| Pro reconciler interruption | Batch dispatch, callback dispatch and workflow progress recover |

## Verify

Every job and run id from step 1 is either complete with its effect checked, or recorded as unresolved with an owner.

## See also

- [Reliability and recovery](../explanation/reliability-and-recovery.md): the startup recovery limit and unknown outcomes.
- [Delivery](../explanation/delivery.md)
