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
| `expires` | `Time::Span` | `3.days` | From job construction; a job past it is dead-lettered unrun |
| `timeout` | `Time::Span` | `2.seconds` | Validated (> 0); not enforced on running jobs |
| `failed_ttl` | `Time::Span` | `7.days` | Validated; unused |
| `dead_letter_ttl` | `Time::Span` | `7.days` | Validated; the Redis DLQ does not expire entries |
| `worker_batch_size` | `Int32` | `10` | 1 to 1000; jobs one worker holds at once |
| `rest_api_enabled` | `Bool` | `false` | Starts the management API in `forge` |
| `stats_enabled` | `Bool` | `true` | |
| `time_location` | `Time::Location` | `America/New_York` | Time zone of `scheduler` cron patterns |
| `reaper_interval`, `reaper_scan_limit` | `Time::Span`, `Int32` | `30.seconds`, `1000` | Expired-job reaper |
| `pipeline_batch_size`, `pipeline_timeout`, `pipeline_max_commands` | `Int32`, `Float64`, `Int32` | `100`, `1.0`, `1000` | Batch size ≤ max commands |
| `middlewares` | `Array(Middleware)` | `[Throttle, Retry, Timeout]` | Add Pro middleware here |
| `store` | `Store` | `RedisStore.from_env` | |
| `payload_encryption(current, previous)` | method | none | Keys for `encrypted_property`; otherwise read from `JOOBQ_PAYLOAD_KEYS` |
| `allow_plaintext_payloads` | `Bool` | `true` | |

Inside the block: `queue name, workers, JobClass, throttle = nil` (workers 1 to 1000), `scheduler(tz) { every ...; cron "..." { } }`, `register_job JobClass`, `error_monitoring(...)`.

## YAML

Searched in order: `./joobq.yml`, `./config/joobq.yml`, `./config/joobq.yaml`, `./joobq.yaml`, `$JOOBQ_CONFIG_PATH`, `$JOOBQ_CONFIG_FILE`, `~/.joobq/joobq.yml`, `/etc/joobq/joobq.yml`; environment files `./config/joobq.<env>.yml` (from `JOOBQ_ENV`, `RACK_ENV`, `CRYSTAL_ENV`, default `development`) are checked first.

| Key under `joobq:` | Contents |
| --- | --- |
| `settings` | `default_queue`, `retries`, `expires`, `timeout`, `failed_ttl`, `dead_letter_ttl`, `worker_batch_size`, `timezone` |
| `queues` | `<name>: {job_class, workers, throttle: {limit, period}}` |
| `redis` | `host`, `port`, `password`, `pool_size`, `pool_timeout`, `url`, `tls_verify`, `ca_file` |
| `middlewares` | list of `{type: throttle|retry|timeout}` |
| `pipeline` | `batch_size`, `timeout`, `max_commands` |
| `features` | `rest_api`, `stats` (booleans) |
| `error_monitoring` | `alert_thresholds`, `time_window`, `max_recent_errors` |
| `schedulers` | list of `{timezone, cron_jobs: [{pattern, job, args}], recurring_jobs: [{interval, job, args}]}`: loaded but never fired by Core |

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
| `JOOBQ_EVENTS_MAX_BYTES` | 64 MiB | Byte cap of the `joobq:events` stream (also capped near 50,000 entries); `0` turns the byte cap off |
| `LOG_LEVEL` | `info` | Read by `Log.setup_from_env` |
| `JOOBQ_PRO_LICENSE` | none | Pro licence key |
| `JOOBQ_PRO_BUILD_ID` | none | Build id of a Pro workflow worker |
| `CRYSTAL_WORKERS` | Crystal's | Crystal runtime threads (multithreaded builds); JoobQ does not read it |

JoobQUI's own variables are in [Configuration and environment variables](https://joobq-website.onrender.com/docs/reference/configuration-and-env-vars).

## See also

- [Connect to Redis](../how-to/connect-to-redis.md)
- [Core API](core-api.md)
