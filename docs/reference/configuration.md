---
description: Every JoobQ Core setting (JoobQ.configure properties, YAML keys, JOOBQ_* and REDIS_* environment variables) with its default, and the Pro variables.
---

# Configuration

*Reference · Core · Pro*

## `JoobQ.configure` properties

| Property | Type | Default | Notes |
| --- | --- | --- | --- |
| `default_queue` | `String` | `"default"` | |
| `retries` | `Int32` | `3` | 0 to 100; retries after the first run |
| `retry_jitter` | `Bool` | `true` | Each retry waits a random time between 1 second and `min(2^n s, 1 h)`; `false` waits the full `min(2^n s, 1 h)` |
| `expires` | `Time::Span` | `3.days` | From job construction; a job past it is dead-lettered unrun |
| `timeout` | `Time::Span` | `2.seconds` | Validated (> 0); Core does not enforce it on running jobs. Pro's `Job#with_timeout` uses it as its default limit |
| `failed_ttl` | `Time::Span` | `7.days` | Validated; unused |
| `dead_letter_ttl` | `Time::Span` | `7.days` | Validated; the Redis DLQ does not expire entries |
| `worker_batch_size` | `Int32` | `10` | 1 to 1000; jobs one worker holds at once |
| `rest_api_enabled` | `Bool` | `false` | Starts the management API in `forge` |
| `stats_enabled` | `Bool` | `true` | |
| `time_location` | `Time::Location` | `America/New_York` | Time zone of `scheduler` cron patterns; set by `timezone` in YAML or `JOOBQ_TIMEZONE`. The process zone, `Time::Location.local`, is never changed |
| `reaper_interval`, `reaper_scan_limit` | `Time::Span`, `Int32` | `min(30.seconds, owner_ttl)`, `1000` | Expired-job reaper, which also reclaims dead processes' jobs. `reaper_interval` is also the cadence of the expired-job scan of every queue (100 ms, the minimum, scans each queue ten times a second). The reaper is built on first use (`forge`): set both before it. Set above `owner_ttl` alone it is clamped to the TTL with a warning; set together with `owner_ttl` and above it, it raises `ConfigValidationError` |
| `owner_ttl` | `Time::Span` | `30.seconds` | How long after its last beat a process counts as dead (1 second to 1 hour); also `owner_ttl` in YAML settings and `JOOBQ_OWNER_TTL` (an invalid value raises `ConfigValidationError`). A crashed process's jobs are back on their queue at most `owner_ttl + reaper_interval` after the crash (60 s by default). **Use the same value on every process that shares a Redis** (see below). An assigned `store` keeps its own TTL unless `owner_ttl` was set here |
| `pipeline_batch_size`, `pipeline_timeout`, `pipeline_max_commands` | `Int32`, `Float64`, `Int32` | `100`, `1.0`, `1000` | Batch size ≤ max commands |
| `middlewares` | `Array(Middleware)` | `[Throttle, Retry, Timeout]` | Add Pro middleware here |
| `store` | `Store` | `RedisStore.from_env` | |
| `payload_encryption(current, previous)` | method | none | Keys for `encrypted_property`; otherwise read from `JOOBQ_PAYLOAD_KEYS` |
| `allow_plaintext_payloads` | `Bool` | `true` | |

Liveness is judged by the reader's own `owner_ttl`, while each process beats at a third of its own: with different values a process with a short TTL treats a live process with a long one as dead, reclaims its jobs and fences it. Roll a change of `owner_ttl` out to every process at once (stop all, then start), or lower it first on a fleet that is stopped; never mix values while jobs are running.

Inside the block: `queue name, workers, JobClass, throttle = nil` (workers 1 to 1000), `scheduler(tz) { every ...; cron "..." { } }`, `register_job JobClass`, `error_monitoring(...)`.

## YAML

Searched in order: `./joobq.yml`, `./config/joobq.yml`, `./config/joobq.yaml`, `./joobq.yaml`, `$JOOBQ_CONFIG_PATH`, `$JOOBQ_CONFIG_FILE`, `~/.joobq/joobq.yml`, `/etc/joobq/joobq.yml`; environment files `./config/joobq.<env>.yml` (from `JOOBQ_ENV`, `RACK_ENV`, `CRYSTAL_ENV`, default `development`) are checked first.

| Key under `joobq:` | Contents |
| --- | --- |
| `settings` | `default_queue`, `retries`, `retry_jitter`, `expires`, `timeout`, `failed_ttl`, `dead_letter_ttl`, `worker_batch_size`, `owner_ttl`, `reaper_interval`, `timezone` |
| `queues` | `<name>: {job_class, workers, throttle: {limit, period}}` |
| `redis` | `host`, `port`, `password`, `pool_size`, `pool_timeout`, `url`, `tls_verify`, `ca_file` |
| `middlewares` | list of `{type: throttle|retry|timeout}` |
| `pipeline` | `batch_size`, `timeout`, `max_commands` |
| `features` | `rest_api`, `stats` (booleans) |
| `error_monitoring` | `alert_thresholds`, `time_window`, `max_recent_errors` |
| `schedulers` | list of `{timezone, cron_jobs: [{pattern, job, args}], recurring_jobs: [{interval, job, args}]}`: parsed into `config.scheduler_configs` for a host to read, never fired by Core |

## Environment variables

| Variable | Default | Effect |
| --- | --- | --- |
| `REDIS_URL` | none | `redis://`, `rediss://` or `unix://`; wins over host/port/password |
| `REDIS_HOST`, `REDIS_PORT`, `REDIS_PASS` | `localhost`, `6379`, none | |
| `REDIS_POOL_SIZE`, `REDIS_POOL_TIMEOUT` | `500`, `2.0` s | Per process |
| `REDIS_CONNECT_TIMEOUT`, `REDIS_COMMAND_TIMEOUT`, `REDIS_OPERATION_TIMEOUT` | `5.0` s each | |
| `REDIS_TLS_VERIFY`, `REDIS_CA_FILE` | `true`, system CAs | |
| `JOOBQ_ENV`, `RACK_ENV`, `CRYSTAL_ENV` | `development` | Pick `./config/joobq.<env>.yml` |
| `JOOBQ_CONFIG_PATH`, `JOOBQ_CONFIG_FILE` | none | Entries in the YAML search list |
| `JOOBQ_API_READER_TOKEN`, `JOOBQ_API_OPERATOR_TOKEN`, `JOOBQ_API_ADMIN_TOKEN` | none | Management API tokens, at least 32 bytes each |
| `JOOBQ_PAYLOAD_KEYS`, `JOOBQ_PAYLOAD_KEY` | none | `id:key` entries (first one seals) for `encrypted_property` |
| `JOOBQ_TRAP_SIGNALS` | on | `0`, `false`, `no`: `forge` installs no signal handlers |
| `JOOBQ_EVENTS_MAX_BYTES` | 64 MiB | Byte cap of the `joobq:v1:events` stream (also capped near 50,000 entries); `0` turns the byte cap off |
| `LOG_LEVEL` | `info` | Read by `Log.setup_from_env` |
| `JOOBQ_PRO_LICENSE` | none | Pro licence key |
| `JOOBQ_PRO_BUILD_ID` | none | Build id of a Pro workflow worker |
| `CRYSTAL_WORKERS` | Crystal's | Crystal runtime threads (multithreaded builds); JoobQ does not read it |

JoobQUI's own variables are in [Configuration and environment variables](https://joobq-website.onrender.com/docs/reference/configuration-and-env-vars).

## Redis keys

Every key JoobQ writes is under `joobq:v1:`; `JoobQ::Keys` builds the names (`Keys.queue("default")`), so code that reads JoobQ's data should call it rather than build strings. The Delivery runtime keeps its state under `joobq:v1:<namespace>:` and refuses a namespace that equals one of the segments below.

| Key | Type | Contents |
| --- | --- | --- |
| `joobq:v1:queue:<queue>` | list | Waiting jobs: producers push to the tail, workers claim from the head |
| `joobq:v1:processing:<queue>:<host>:<pid>` | list | Jobs claimed by one process (`joobq:v1:processing:<queue>` is the shared list older workers used) |
| `joobq:v1:processing-owners` | sorted set | Heartbeat of each process that owns a processing list |
| `joobq:v1:delayed_jobs` | sorted set | Scheduled and retrying jobs |
| `joobq:v1:dead_letter`, `joobq:v1:dead_letter:counts` | sorted set, hash | Dead jobs and their count per queue |
| `joobq:v1:stats:<name>` | hash | Counters per queue, and `global` |
| `joobq:v1:retry_lock:<jid>` | string | Makes one failure schedule one retry |
| `joobq:v1:paused:<queue>`, `joobq:v1:config:<queue>` | string, hash | Pause flag and desired concurrency |
| `joobq:v1:worker:<host>:<pid>`, `joobq:v1:workers` | string, sorted set | Worker heartbeat and its index |
| `joobq:v1:events`, `joobq:v1:events:live` | stream, channel | Lifecycle events |
| `joobq:v1:error_counts`, `joobq:v1:recent_errors`, `joobq:v1:error_index` | hash, hash, sorted set | Error records |

A stored job carries its format version as `"v"`. See [Recover and migrate](../how-to/recover-and-migrate.md#upgrade-the-keyspace-from-06) to move a 0.6 keyspace.

## See also

- [Connect to Redis](../how-to/connect-to-redis.md)
- [Core API](core-api.md)
