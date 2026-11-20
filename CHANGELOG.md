# Changelog

## [Unreleased]

### Changed (upgrade note: the keyspace moved)

- **Every Redis key is under `joobq:v1:`.** 0.6 stored a queue's waiting jobs under the bare queue name (a queue
  `default` was the Redis key `default`) and everything else under `joobq:` without a version. Now `JoobQ::Keys` names
  every key (`Keys.queue("default")` is `joobq:v1:queue:default`; processing lists, the delayed set, dead letters,
  stats, retry locks, error records, workers, events and the delivery-bridge marker follow; the pause and config
  flags are `joobq:v1:paused:<queue>` and `joobq:v1:config:<queue>`). Code that built these keys by hand (joobqui,
  joobq-pro) must call `Keys` instead; land joobq-pro (Keys for the delivery-bridge marker, stats, error counts and the
  bare queue list it reads) and joobqui together with this release. Until joobq-pro moves, `Queue#start` also reads the
  0.6 marker `joobq:delivery-bridge:<queue>` (`Keys.legacy_delivery_bridge`, removed at 1.0), so the guard against a
  legacy worker on a leased queue stays on. `Delivery::Ledger`, `Journal` and `Backup` refuse a new delivery namespace named like one of these families (`events`,
  `config`, `queue`, `stats`, `worker`, `workers`, `paused`, `processing`, ...); a namespace of that name that already holds
  delivery data keeps working and logs a warning.
- **Upgrade with every JoobQ process stopped, then run `JoobQ.migrate_keyspace!(queues: [...])` once.** It renames the
  bare lists of the queues you name and every `joobq:` key into the new namespace, refuses while another process has a
  live heartbeat in either namespace, and reports `renamed: 0` and `merged: 0` when run again. Where the new version
  already created a key (a start before the migration), it merges: the stale owner, worker and event keys are dropped,
  sorted sets are united, counters added, and old list items go to the head of the new list; a key whose new name is
  of another type is left and listed in `skipped`. The order is: stop every process, migrate, then start. A version that finds 0.6 keys logs an error at the first `Queue#start`; it does not read them. Running 0.6
  and this version against one Redis at the same time is not supported.
- **Stored jobs carry a format version, `"v": 1`.** A reader refuses a greater version with
  `JoobQ::UnsupportedJobVersion` (a `JSON::ParseException`, so the worker dead-letters the payload unread and whole, and logs a
  message naming the version; redrive it after upgrading). A job without `v` is a 0.6 job and is read as before.

### Fixed

- **The `timezone` setting applies, and no longer changes the process zone (#44).** `config.time_location = "UTC"`
  (also YAML `timezone` and `JOOBQ_TIMEZONE`) used to set the process-wide `Time::Location.local` and never store the
  zone, so `config.time_location` and every `Scheduler.new` default stayed `America/New_York`. It now stores the zone for
  JoobQ's own cron computations and leaves `Time::Location.local` alone; it also takes a `Time::Location`. Merging YAML
  sources keeps the zone of the last source that set one. Code that relied on the process zone changing must set
  `Time::Location.local` itself.

- **A live process re-drives the jobs whose outcome it could not store.** When Redis was away as a job ended, the
  worker could not remove the job's copy from its own processing list (or could not store a failure), and nothing
  returned the copy until the process was restarted: the heartbeat that protects the list came back by itself. The
  claim is now kept as `retained` in `InFlight` (it stays counted while the cleanup runs, and turns retained in one
  step when the cleanup fails), and the owner heartbeat loop puts each retained copy back at the head of its queue
  (`RedisStore#redrive_retained`, one atomic script per copy, oldest claim first, at most once per copy; a copy
  another process already reclaimed is forgotten). `Store#cleanup_job` and `#mark_job_completed` now return `false`
  instead of `nil` after logging, and the abstract signatures say `Bool`. **A job that succeeded but whose cleanup could
  not be stored runs again after an outage**: delivery stays at-least-once, so jobs must be safe to run twice.
- **Shutdown counts the retained copies it has to put back.** A copy still retained at shutdown is returned to its queue
  in a step of its own and counted in `JoobQ.abandoned_jobs`, so the process exits with status 3 (it used to exit 0 with
  `abandoned_jobs: 0`). A copy the owner had already re-driven is not counted.

## 0.7.2

### Fixed

- **Crash recovery no longer takes the in-flight jobs of a queue whose name extends another's.** With queues `default`
  and `default:x`, recovery on `default` read the processing lists of `default:x`
  (`joobq:processing:default:x:<host>:<pid>`) as lists of a dead owner `x:<host>:<pid>` of `default` and moved their
  jobs into `default` while a live worker still held them: the job ran on the wrong queue, and twice.
  `processing_queue_size("default")` counted them too. A key now belongs to a queue only when what follows the
  queue name has the shape of an owner id, `<host>:<pid>` with exactly one colon; `RedisStore#owner_id=` refuses any
  other shape. Glob characters in a queue name (`* ? [ ]`) are matched literally. Remaining case: the pre-0.6 shared
  list of a queue named `a:b:c` still looks like an owner list of queue `a`; it exists only while 0.5 workers run.

## 0.7.1

### Fixed

- **A `NonRetryableError` keeps its message exactly as raised.** 0.7.0 appended ` [JQ-302] https://joobq.io/errors/JQ-302`
  to the message of `NonRetryableError` and of your own subclasses, which changed what dead-letter entries,
  workflow failures and anything matching the message saw. The message is yours again; the code is still on the
  error (`joobq_error_code`). Errors JoobQ raises itself keep the suffix.

## 0.7.0 (MINOR)

### Added

- **Diagnostic error codes**: JoobQ's own errors (configuration, Redis durability, jobs and queues, payload
  encryption) end their message with ` [JQ-<n>] https://joobq.io/errors/JQ-<n>`; `JoobQ::ErrorCodes` is the catalog
  (`[]`, `all`, `to_json`) and `docs/reference/error-codes.md` lists every code.
- **`GET /healthz` and `GET /readyz` on the management API**, answered without a token (GET or HEAD, exact path):
  `/healthz` is 200 `{"status":"ok"}` without touching Redis; `/readyz` is 200 `ready` when Redis answers PING and
  JoobQ is not shutting down, else 503 `not_ready`, with `checks: {redis, shutdown}`. Every other route still needs
  a token. The Redis answer of `/readyz` is cached for 1 second and one probe runs at a time, so unauthenticated
  requests cannot exhaust the Redis pool; both answers carry `Cache-Control: no-store`.
- **`retry_jitter` is validated in YAML** (a value that is not a boolean is a JQ-104 validation error) and can be
  overridden with `JOOBQ_RETRY_JITTER`.

### Fixed

- **Starting a second `Queue` of a running queue name no longer runs a job twice** (#36). Restart recovery used to
  put the first instance's in-flight jobs back on the queue. It now runs only for the first instance of a name in
  this process, and not while a claim of that queue is still in flight after `stop!`. `stop!` puts back claims no
  worker had received (a `JoobQ.shutdown` requeues them itself). A second instance still starts its workers.

### Changed

- **Messages of coded errors end with their code and URL**: every error that carries a code, including your own
  subclasses of `NonRetryableError`, now has a message ending in ` [JQ-<n>] https://joobq.io/errors/JQ-<n>`, so
  dead-letter entries and logs show it (for example `card declined [JQ-302] https://joobq.io/errors/JQ-302`). A
  coded error raised without a message shows the catalog title instead of an empty message. The library's hooks are
  `joobq_error_code` (class-level declaration and instance accessor), so a subclass keeps any `error_code` of its own.
- **Retries wait a random time between 1 second and the exponential ceiling** (`min(2^n s, 1 h)`), so jobs that
  failed together no longer retry at the same moment; the first retry still waits exactly 1 second, and no retry
  waits less. The retry lock still lasts past the full ceiling. `JoobQ.config.retry_jitter = false` (or
  `settings.retry_jitter: false` in YAML) restores the fixed delays.
- **`JoobQ.config.queues` is the one queue registry.** `JoobQ.queues` and `QueueFactory.queues` return that same
  `Hash` after creating the YAML-configured queues missing from it; the memoised copy is gone. A queue added with
  `JoobQ.queues[name] = queue` (as the joobq-pro engine does) is registered like any other, and the delayed-job
  scheduler, the expired-job reaper and the queue metrics now serve it and YAML-configured queues. A YAML entry
  that cannot be created (job type not registered) is logged once and retried only after a job type is registered.
  A queue added at runtime is not started for you, and the `Hash` is not synchronized: register from one fiber.

### Deprecated

- `QueueFactory.clear_queues_cache` does nothing now and goes in the next minor release. To rebuild a queue after
  editing `queue_configs`, delete it from `JoobQ.queues` and call `JoobQ.queues` again, or call `JoobQ.reset_config`.

## 0.6.1 (PATCH)

### Changed

- **Workers no longer busy-poll for jobs.** Each queue now runs one dispatcher fiber on a dedicated blocking
  connection that claims the head job with `BLMOVE` and hands it (plus a pipelined batch top-up) to the worker
  fibers over an in-process channel. Idle workers block on that channel instead of polling Redis, so idle Redis
  load and the number of Redis connections no longer grow with the worker count, and a job on an idle queue is
  picked up in sub-millisecond time (previously up to the 100 ms poll). Claims still land in this process's own
  processing list, so FIFO order and crash recovery are unchanged; blocking connections are O(active queues). A
  non-Redis store, or a `Worker` run outside `Queue#start`, keeps the previous self-claiming behaviour.

## 0.6.0 (MINOR)

### Changed

- **Queues are first in, first out.** Producers still `RPUSH` to the tail of a queue; workers now claim from the head
  (`BLMOVE queue processing LEFT LEFT` for a single claim, pipelined `LMOVE ... LEFT LEFT` for a batch), so jobs run
  in the order they were enqueued. Until 0.5.x workers claimed from the tail (`BRPOPLPUSH`/`RPOPLPUSH`) and the
  newest job ran first. Delayed and retried jobs still join the tail when they are due, and so do dead-letter
  replays. `RedisStore#list_jobs` (and `Queue#jobs`) list the next job to run first.
- **Redis 6.2 or newer is required** (`BLMOVE` and `LMOVE`). CI tests Redis 7.4 and 8.0. A queue on a server
  without `LMOVE` refuses to start (`ArgumentError` from `Queue#start`) instead of failing every claim.
- **Each process claims into its own processing list.** A claim now lands in `joobq:processing:<queue>:<owner>`,
  one list per process, and the process publishes a heartbeat in the `joobq:processing:owners` sorted set. The
  shared `joobq:processing:<queue>` list is kept only for jobs left by older (0.5) workers and is migrated once no
  0.6 process is live. Inspection, metrics and the reaper read every processing list of a queue, so processing
  counts and the dashboard are unchanged.
- **Jobs abandoned at shutdown run next.** `JoobQ.shutdown` puts the jobs it gives up on back at the head of their
  queue, in the order this process claimed them (`RedisStore#requeue_many_from_processing`; jobs still settling a
  failure at the deadline are put back a moment later, in front of them).

### Fixed

- **Crash recovery is complete and safe.** `Queue#start`, the expired-job reaper and
  `POST /joobq/queues/:name/reprocess` return **every** job a crashed or stopped process left in processing back to
  the head of its queue, in claim order, so the recovered jobs run before newer work. Before 0.6 `Queue#start` moved
  at most one job and blocked half a second when there was none. Recovery reclaims a processing list only once its
  owner's heartbeat has lapsed (or at start-up, this process's own leftover list), so a running process's in-flight
  jobs are never moved out from under it: a new process starting beside live workers no longer re-runs their jobs,
  and the earlier window where a finishing job's `LREM` could drop another claimant's entry is gone.

### Upgrading

- **Redis 6.2+** is required before deploying 0.6.
- During a rolling upgrade from 0.5, order is mixed until every worker runs 0.6: a 0.5 worker takes the newest job,
  a 0.6 worker the oldest. No job is lost.
- **Stop 0.5 workers before relying on 0.6 recovery.** 0.5 workers claim into the shared
  `joobq:processing:<queue>` list and publish no heartbeat, so a live 0.5 worker cannot be detected. A 0.6 process
  migrates that shared list to the head of the queue only when no 0.6 process is live, and cannot tell a live 0.5
  worker's in-flight job from an abandoned one. Drain the 0.5 workers (`SIGTERM`) first; then the first 0.6 process
  migrates whatever they left behind.
- A crashed 0.6 process's jobs are recovered automatically once its heartbeat lapses (within `OWNER_TTL`, 30 s), by
  the next `Queue#start`, the reaper, or `reprocess`. Jobs stay safe to run twice, as after any crash.
