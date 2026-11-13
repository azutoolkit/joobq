---
description: The public Crystal API of JoobQ Core 0.5.6 (jobs, queues, workers, dead letters, lifecycle) and its HTTP management routes.
---

# Core API

*Reference · Core*

## `JoobQ::Job` (include it in a struct or class)

| Member | Signature | Description |
| --- | --- | --- |
| `enqueue` | `self.enqueue(**args) : String` | Builds the job with `args` and pushes it to its queue; returns the `jid` |
| `batch_enqueue` | `self.batch_enqueue(jobs : Array(self), batch_size = 1000) : Nil` | Pipelined enqueue; `batch_size` must be 1 to 1000 and is only validated |
| `delay` | `self.delay(for wait_time : Time::Span, **args) : UUID` | One job, due after `wait_time` |
| `enqueue_at` | `self.enqueue_at(time : Time::Span, **args) : UUID` | Same as `delay` (takes a span) |
| `schedule` | `self.schedule(every : Time::Span, **args)` | Calls `perform` every span in this process; no queue, retries or dead letter |
| `perform` | `self.perform(**args)` / `abstract def perform` | Runs the job now, in this process |
| properties | `jid : UUID`, `queue : String`, `retries : Int32`, `max_retries : Int32`, `expires : Int64` (Unix ms), `status : Status`, `error` | Stored with your own properties as JSON |
| `Status` | `Completed`, `Dead`, `Enqueued`, `Expired`, `Retrying`, `Running`, `Scheduled` | With `<status>?` and `<status>!` methods |
| `JoobQ::NonRetryableError` | exception class | Raise it (or a subclass) to dead-letter without retrying |

## `JoobQ` module

| Member | Signature | Description |
| --- | --- | --- |
| `configure` | `configure(&)` | Yields the `JoobQ::Configure` instance (see [Configuration](configuration.md)) |
| `forge` | `forge(trap_signals = true, shutdown_timeout = 15.seconds)` | Starts schedulers, the delayed-job mover, the expiry reaper, every queue and (if enabled) the management API; with `trap_signals` it blocks and handles SIGTERM, SIGINT, SIGHUP |
| `shutdown` | `shutdown(timeout = 15.seconds) : Bool` | Stops the API, schedulers and queues, waits for running jobs, requeues those still running at the deadline; `false` if already shut down |
| `abandoned_jobs` | `: Int32` | Jobs put back on their queue by the last shutdown |
| `enqueue` | `enqueue(queue_name : String, json : String) : String` | Enqueues raw JSON on a configured queue; raises `JoobQ::UnknownQueue` |
| `queues` | `: Hash(String, BaseQueue)` | The one queue registry, `JoobQ.config.queues`, after creating the YAML-configured queues missing from it. Engines add a queue with `JoobQ.queues[name] = queue`; it is not started for you, and the `Hash` is not synchronized (one writer) |
| `[]` | `JoobQ[name]` | A registered queue: `JoobQ.queues[name]` |
| exit codes | `EXIT_CLEAN = 0`, `EXIT_ABANDONED = 3` | Exit status after a signal; `1` on a second signal more than 1 s after the first |

## Queue (`JoobQ::Queue(T)`)

| Member | Description |
| --- | --- |
| `pause!`, `resume!`, `paused?` | Flag `joobq:queue:<name>:paused` in Redis, read by workers of every process (cached 500 ms) |
| `resize(count)` | Sets this process's worker count and stores it in `joobq:queue:<name>:config` |
| `size`, `clear`, `stop!` | Waiting jobs, delete them, stop this process's workers |
| `name`, `job_type`, `total_workers`, `running_workers`, `throttle_limit` | Read-only properties |

## `JoobQ::DeadLetterQueue`

| Member | Description |
| --- | --- |
| `count(queue = nil) : Int64`, `counts : Hash(String, Int64)` | Entries in `joobq:dead_letter`, overall or per queue |
| `page(offset = 0, limit = 50, queue = nil) : Array(Entry)` | One page of entries |
| `find(jid) : Entry?` | One entry |
| `redrive(jids) : Outcome` | Puts entries back on their queue with `retries = max_retries`, a new `expires` and no error |
| `purge(jids) : Outcome`, `purge_all(queue = nil) : Int32` | Deletes entries |
| `Entry` | `jid`, `queue`, `failed_at`, `error : String?`, `job : JSON::Any`, `redrivable?` |
| `Outcome` | `succeeded : Int32`, `missing`, `unredrivable`, `conflicted : Array(String)` |

## Other classes

| Class | Use |
| --- | --- |
| `JoobQ::WorkerRegistry.new.start` | Heartbeat every 10 s to `joobq:worker:<id>` (TTL 30 s), indexed in `joobq:workers` |
| `JoobQ::Events.subscribe(JoobQ::RedisEventSink.new)` | Writes this process's lifecycle events to `joobq:events` and publishes them on `joobq:events:live` |
| `JoobQ::JSONLogFormatter` | `Log::Formatter` for NDJSON log records |
| `JoobQ::ManagementPolicy.from_env` | Reads `JOOBQ_API_READER_TOKEN`, `JOOBQ_API_OPERATOR_TOKEN`, `JOOBQ_API_ADMIN_TOKEN` |
| `JoobQ::Delivery::Runtime` | Opt-in leased runtime, **Preview** (see [Delivery](../explanation/delivery.md)) |

## HTTP management API

Off by default (`rest_api_enabled = false`). With it on, `forge` listens on `127.0.0.1:8080`. Every route, the health check included, needs `Authorization: Bearer <token>`: `GET`/`HEAD` need a reader, `DELETE` and paths containing `/reset` or `/config` need an admin, other methods an operator. Missing or unknown token: `401`; role too low: `403`; body over 1 MiB: `413`.

| Method | Path | Role |
| --- | --- | --- |
| `GET` | `/joobq/health/check` | reader |
| `GET` | `/joobq/jobs/registry` | reader |
| `GET` | `/joobq/jobs/retrying`, `/joobq/jobs/dead` | reader |
| `GET` | `/joobq/errors/stats`, `/joobq/errors/recent`, `/joobq/errors/by-type`, `/joobq/errors/by-queue` | reader |
| `GET` | `/joobq/pipeline/health`, `/joobq/pipeline/stats` | reader |
| `POST` | `/joobq/jobs` (deprecated) | operator |
| `POST` | `/joobq/queues/:queue_name/reprocess` | operator |
| `POST` | `/joobq/jobs/:job_id/retry` | operator |
| `POST` | `/joobq/pipeline/stats/reset` | admin |

JoobQ ships no OpenAPI file for these routes. Pro adds routes to the same API when its metrics middleware starts: see [Pro API](pro-api.md).

## See also

- [Configuration](configuration.md)
- [Secure management access](../how-to/secure-management-access.md)
