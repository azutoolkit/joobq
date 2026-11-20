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
5. Inspect waiting, processing (`joobq:v1:processing:<queue>`), delayed and dead-letter state; for Delivery also leases and receipts.
6. Replay one reviewed job, watch it, then the rest. Record every outcome you could not resolve.
7. Before you start consumers again after a crash, stop any process still running the queue: recovery returns every job of a process whose heartbeat has lapsed (30 s), and none of a live one's.

## Migrate to another processing path

1. Use a separate namespace for the new path (for example a new Delivery runtime namespace).
2. Stop or redirect producers, then drain or account for the old work.
3. Validate the new path with a small workload, keeping the old state until it is reconciled.
4. Write down the rollback boundary: do not start old binaries against state written by the new release until you have tested that they can read it.

## Upgrade the keyspace from 0.6

0.6 kept a queue's waiting jobs under the bare queue name and everything else under `joobq:` with no version. Since this release every key is under `joobq:v1:` (see [Redis keys](../reference/configuration.md#redis-keys)); a version that finds 0.6 keys logs an error at the first `Queue#start` and does not read them.

1. Stop every JoobQ process, workers and producers included. The migration refuses while another process has a live heartbeat.
2. Run `JoobQ.migrate_keyspace!(queues: ["default", "exports"])` once, naming every queue that has jobs. It renames the bare lists of those queues and each `joobq:` key into the new namespace, and returns a report: keys `renamed`, keys `merged` into a new key that a start had already created (stale owner and worker keys are dropped, sorted sets united, counters added, old list items put at the head of the new list), and `skipped` keys whose new name is of another type.
3. Run it again: it must report `renamed: 0` and `merged: 0`. Start the new processes.

A job stored before this release has no `v` field and is read as before. A job with a greater `v` than the process knows is dead-lettered unread, payload intact, and the worker log names the version; redrive it after upgrading that process.


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
- [Redis keys](../reference/configuration.md#redis-keys): every key JoobQ writes.
- [Delivery](../explanation/delivery.md)
