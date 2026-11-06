---
description: The public Crystal API of JoobQ Pro 0.2.4 beyond the workflow DSL: the workflow worker and client, schedules, rate limits, batches, unique jobs, metrics and licensing.
---

# Pro API

*Reference · Pro*

The DSL that defines workflows has its own page: [Workflow DSL](workflow-dsl.md).

## `JoobQPro::Workflows::Worker`

| Member | Signature or default | Description |
| --- | --- | --- |
| `new` | `activity_workers = 10, orchestrators = 2, scheduler = true, build_id = ENV["JOOBQ_PRO_BUILD_ID"]?, activity_timeout = 30.seconds, delivery = nil, archive = nil` | One process's workflow engine |
| `register(blueprint)`, `register(catalog)` | returns the worker | DSL forms: install the activity handlers and publish the definitions |
| `register(definition)` | returns the worker | Publishes a definition built without the DSL; installs no handlers |
| `start` | | Starts activity workers, orchestrators and (with `scheduler: true`) the schedule leader |
| `client` | `Workflows::Client` | Starts and inspects runs (below) |
| `schedules` | `Workflows::Schedules` | Workflow schedules (below) |

## `JoobQPro::Workflows::Client`

| Method | Signature | Description |
| --- | --- | --- |
| `start` | `start(name, input = nil, id = UUID.random.to_s, ...)` | Starts a run; returns its id |
| `result` | `result(id, timeout = 30.seconds) : JSON::Any` | Waits for the run; raises `WorkflowFailed` with its failure |
| `signal` | `signal(id, name, payload = nil) : Bool` | Delivers a signal |
| `query` | `query(id, name) : JSON::Any` | Answers a declared query from the run's state |
| `describe`, `history` | `describe(id) : State`, `history(id, after_seq = 0, limit = 200)` | Current state, history events |
| `cancel`, `terminate` | `(id, reason)` : `Bool` | Cancel runs compensations; terminate does not |
| `retry_step` | `retry_step(id, step_id) : Bool` | Runs a failed step again while the run is open |
| `list`, `search` | `(status or filter, offset = 0, limit = 50)` | Runs by status or by search attributes |
| `promote_build`, `retire_build`, `build_ids` | | Worker build ids |

## `JoobQPro::Workflows::Schedules`

| Method | Description |
| --- | --- |
| `create(id, workflow, **options)` | Creates a schedule; `id` matches `[A-Za-z0-9_-]{1,64}` |
| `update`, `pause(id)`, `resume(id)`, `delete(id)`, `get(id)`, `list(offset = 0, limit = 50, upcoming = 3)` | Manage schedules |
| `trigger(id, overlap = nil, force = false)` | Starts a run now |
| `backfill(id, from, to, overlap = AllowAll)` | Starts the runs for past fire times |

| Schedule option | Type | Default | Description |
| --- | --- | --- | --- |
| `cron` / `interval_ms` | `String` / `Int64` | none | Exactly one of the two |
| `timezone` | `String` | `"UTC"` | IANA zone of the cron expression |
| `overlap` | `OverlapPolicy` | `Skip` | `Skip`, `BufferOne`, `AllowAll`, `CancelPrevious` |
| `catchup_window_ms` | `Int64` | `60000` | Missed fire times at most this old are still run |
| `jitter_ms` | `Int64` | `0` | Fixed delay per fire time, derived from the schedule id |
| `max_runs`, `start_at`, `end_at` | `Int64?` | none | Bounds |
| `input`, `search_attributes`, `paused`, `note` | | | |

## Rate limits

| Member | Description |
| --- | --- |
| `JoobQPro::RateLimit.new(count, period, key_suffix = nil)` | `count > 0`; `period` 1 ms to 24 h |
| `JoobQPro::RateLimiter.reserve(key, limit, client) : Permit` | Atomic sliding-window reservation in `joobq_pro:rate_limit:v1:<key>`; `Permit(allowed, retry_after_ms)` |
| `JoobQPro::RateLimiter.get_count`, `.retry_after`, `.clear` | Read and reset a window |
| `include JoobQPro::RateLimited` + `rate_limit count:, period:, key_suffix:` | Declares the job class's limit |
| `JoobQPro::RateLimitMiddleware` | Add to `config.middlewares`; a denied job goes back to the delayed set without using a retry |

## Batches and unique jobs (Preview)

| Member | Description |
| --- | --- |
| `JoobQPro::Durable::Batches.new(runtime)` | `create(id, description, callbacks)`, `add(id, queue, request_id, payload)`, `seal(id)`, `snapshot(id)`, `reconcile` |
| `JoobQPro::Durable::UniqueJobs.new(runtime)` | `admit(queue, key, request_id, payload, duration = 1.hour, mode = UntilExecuting)`, `release(queue, key, owner)` |
| `JoobQPro::UniquenessMode` | `UntilExecuting`, `UntilExecuted`, `WhileLocked` |

Both need a `JoobQ::Delivery::Runtime`.

## Metrics and licensing

| Member | Description |
| --- | --- |
| `JoobQPro::Middleware::Metrics.instance` | Add to `config.middlewares`; registers `GET /joobq/queues`, `/joobq/metrics`, `/joobq/percentiles`, `/joobq/alerts` and `POST /joobq/alerts/:id/acknowledge` on Core's management API |
| `JoobQPro.shutdown(timeout = 15.seconds) : Bool` | Stops workflow workers and the metrics collector; call it before `JoobQ.shutdown` |
| `JoobQPro.licensed?`, `.license`, `.tier`, `.feature?(name)` | Licence state from `JOOBQ_PRO_LICENSE` |
| `JoobQPro::LicenseTier` | `Pro`, `Enterprise`, `Trial` |

## See also

- [Workflow DSL](workflow-dsl.md)
- [Workflow lifecycle controls](workflow-lifecycle-controls.md)
