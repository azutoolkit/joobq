---
description: What JoobQ Core promises after each failure, when a job body can run twice, and what it does not guarantee.
---

# Delivery guarantees

*Reference · Core*

JoobQ Core delivers **at least once**: a job accepted by Redis runs one or more times, never exactly once. Every row below that says "yes" is a documented duplicate, not a bug. Make `perform` safe to run twice; [Write idempotent jobs](../how-to/write-idempotent-jobs.md) shows how.

## Failure scenarios

| Scenario | What happens | Body can run twice? | Spec |
| --- | --- | --- | --- |
| `perform` raises | The retry is scheduled in one atomic step, after a backoff, with the same `jid`, until `retries` is used up; then the job is dead-lettered. A `NonRetryableError` is dead-lettered at once (the body runs once), and so is a job whose retry cannot be stored. An unparseable payload is dead-lettered without running | Yes: up to `1 + max_retries` runs | `spec/retry_double_schedule_spec.cr` "are retried up to their budget and then dead-lettered exactly once"; `spec/failure_lifecycle_spec.cr` "dead-letters a NonRetryableError at once, whatever retries are left" |
| Process killed (SIGKILL, OOM, power loss) | The job stays in the process's processing list; once its heartbeat lapses, the reaper returns it to the head of its queue and it runs from the start | Yes, if the body had started | `spec/recovery_timing_spec.cr` "returns a SIGKILLed owner's jobs inside TTL + reaper interval" |
| Process frozen past `owner_ttl` (long pause, frozen container, partition) | The process is judged dead and its jobs run elsewhere. When it wakes, its outcome is refused and dropped with a warning: nothing is retried, dead-lettered or counted for it | Yes | `spec/stale_owner_fence_spec.cr` "a whole worker whose process was frozen past the TTL" |
| Graceful shutdown (SIGTERM, SIGINT, SIGHUP) | Workers claim nothing more and running jobs finish. An idle or lightly loaded queue exits 0 once they do. Claims already staged for workers stay claimed and are returned only at the deadline, counted as abandoned (next row) | No, when nothing is abandoned | `spec/shutdown_spec.cr` "forge shuts down on SIGTERM: waits for the running job, then exits 0"; `spec/queue_stop_buffered_claims_spec.cr` "leaves them claimed during a shutdown, whose own requeue puts them back at the head" |
| Shutdown deadline with jobs still running or staged (15 s by default) | Every unfinished job is put back at the head of its queue and counted in `abandoned_jobs`; exit status 3. A fiber cannot be killed, so the old execution may keep running; JoobQ ignores its outcome | Yes, for a job that was running | `spec/shutdown_spec.cr` "returns ALL stuck jobs to their queue at the deadline, exits 3" |
| Redis unreachable when a job finishes | The finished job's copy is retained; the owner heartbeat re-drives it about every second once Redis answers, and it runs again. A retry or dead letter that committed is one atomic step and is not re-driven; if Redis fails the retry write and then the dead-letter write, the copy is retained and re-driven too, without spending retry budget | Yes | `spec/retained_redrive_spec.cr` "keeps the copy of a job that succeeded, then re-drives it, once, when Redis is back" |
| Dead letter | Never re-run automatically. A redrive enqueues the same `jid` with a full retry budget and a new expiry | Yes, on redrive | `spec/dead_letter_queue_spec.cr` "redrives an entry as a fresh enqueued job" |
| Job past `expires` | Dead-lettered when claimed (or reaped while waiting), without running. A job already running is not interrupted | No | `spec/retry_double_schedule_spec.cr` "an expired job is dead-lettered once and not also scheduled for retry" |
| Same job enqueued twice | Core does not deduplicate: both copies are queued | Yes | `spec/reliability_audit_spec.cr` "has no enqueue deduplication" |
| Redis reply lost on a command | JoobQ never replays it and raises `RedisOutcomeUnknown`: the job may or may not be stored. Enqueueing again may duplicate it | Yes, if you enqueue again | `spec/redis_transport_spec.cr` "does not replay a mutation when its response is lost" |

## Bounds

- **Recovery time.** After a crash a job is back on its queue within `owner_ttl + reaper_interval`: 30 s + 30 s by default (see [Configuration](configuration.md)). With no process running, nothing recovers it until one starts. Use one `owner_ttl` on every process sharing a Redis. Timing is not frozen by the [compatibility policy](compatibility.md).
- **Runs per job.** Retries alone allow `1 + max_retries` runs. Recovery, re-drive and stale owners put the same job back without spending the retry budget, so there is no cap on them.
- **Abandoned jobs.** `JoobQ.abandoned_jobs` counts the jobs a shutdown put back, and `forge` exits 3 when it is above zero. A second signal more than a second after the first exits 1 at once; the running jobs then wait for the heartbeat to lapse. See [Public API](public-api.md).

## What JoobQ does not guarantee

- **Exactly-once effects.** JoobQ cannot know whether a body's side effect happened before the failure.
- **Order.** Jobs are claimed first in, first out and a queue with one active job runs them in enqueue order (`spec/queue_order_spec.cr` "runs A, B, C in enqueue order when a worker is limited to one active job"). Recovered jobs return to the head of the queue and retries to the tail, so a retried job runs after jobs enqueued later; with several workers completion order is not enqueue order.
- **Durability beyond Redis.** An accepted job is as durable as your Redis: `appendonly`, `appendfsync`, RDB and replicas decide what a restart or failover keeps, and an eviction policy other than `noeviction` can drop queue keys. Lost jobs are lost, not duplicated. Core does not check these settings; the Delivery runtime (Preview) does at start (`appendonly yes`, `appendfsync always`, `maxmemory-policy noeviction`). See [Set up Redis and recovery](../how-to/redis-and-recovery.md).
- **Retry budget on re-runs.** A job returned by recovery, re-drive, a stale owner or a missing encryption key (`Encryption::ConfigurationError`: the job is requeued at the tail) runs again without spending a retry.
- **A stored enqueue.** If `enqueue` raises, the job may not be queued. Write intent and state in one database transaction ([outbox](../how-to/transactional-outbox.md)).

## Write for at-least-once

- **Key by the business operation**, for example `order:42:receipt:v1`. `jid` is the same across retries, crash recovery and dead-letter redrives, but a newly built job gets a new one (enqueueing the same object again reuses it), and `perform` sees it as `jid`.
- **Enforce the key where the effect happens**: a unique constraint written in the same transaction as the effect, or the provider's idempotency key.
- **Check the effect before redriving** a dead letter.
- **Core has no unique-job option or dedupe context.** The opt-in [Delivery runtime](../explanation/delivery.md) (Preview) admits a request id once and gives handlers `context.idempotency_key`, but its handlers can still run twice after a lease expires. Pro's unique admission is in [Batches and unique jobs](../explanation/distributed-coordination.md).

For the mechanisms, read [Reliability and recovery](../explanation/reliability-and-recovery.md).
