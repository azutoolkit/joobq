# Changelog

## 0.8.1

A patch release: one data-loss fix in the keyspace migration, and a test-only CI change.

### Fixed

- **`JoobQ.migrate_keyspace!` no longer deletes a queue's waiting jobs when the queue is named like a transient key.** A
  queue called `events`, `workers`, `processing-owners`, `events:trim_lock`, `worker:<id>` or `delivery-bridge:<queue>` kept its 0.6 waiting
  jobs under that bare name. When `joobq:v1:queue:<name>` already existed (a 0.8 process had enqueued to it or started
  before the migration), the merge took the bare list for JoobQ's own stale `joobq:events` (and so on) key, deleted it
  and counted it as merged: the waiting jobs were lost and the run exited normally. A key is dropped as transient only
  when it is a real 0.6 `joobq:` key, that is when the name it migrates to is the one in the way (`joobq:events` to
  `joobq:v1:events`); a queue list migrates to `joobq:v1:queue:<name>`, so it is merged into that list (old jobs at the
  head, in order), including a queue literally named `joobq:events` or `joobq:workers`.
  Upgrade note: if you have not migrated yet, use 0.8.1. If you migrated with 0.8.0 and a queue of yours had one of
  those names while its `joobq:v1:queue:<name>` list already existed, its 0.6 jobs were dropped: check that queue and
  enqueue them again from your source of truth (the 0.6 list is gone from Redis; a backup or RDB snapshot from before the
  migration still holds it).

### Changed (CI)

- **The delivery batch renewal spec no longer races the clock (#76).** "renews completed handlers while another handler in
  their batch is blocked" used a 300 ms lease and a fixed 450 ms sleep and failed on slow Redis legs. It now uses a 2 s
  lease, waits for the renewed deadlines in Redis, holds the claims past their original deadlines, and gives its final
  waits a window that scales with the lease. Test only; no source change.

## 0.8.0

This release holds breaking changes (the keyspace move, the `allow_plaintext_payloads` default, redacted API payloads, the
removal of `JoobQ.scheduler`), so it is a minor release under the [compatibility policy](docs/reference/compatibility.md),
not a patch. JoobQ Pro and JoobQUI still declare `joobq < 0.8.0` / `= 0.7.2`: move them together with this release (they
build keys by hand today, see the keyspace upgrade note below) before upgrading either of them to 0.8.0.

### Changed (CI)

- **CI tests the Redis and Crystal versions the documentation claims.** The specs, the TLS fixture and the two Redis
  smokes ran on Redis 8.0.6 and Crystal 1.22.1 only, although the README, `shard.yml` and the 0.6.0 notes name Redis 6.2
  and Crystal 1.22.0 as the floors (and the 0.6.0 note that "CI tests Redis 7.4 and 8.0" had stopped being true). They now
  run on Redis 6.2.24 (the floor, `REDIS_HOST` and `REDIS_URL`), 7.4.12 and 8.0.6 on Crystal 1.22.1, and on Crystal 1.22.0
  (the floor) and `latest` on Redis 8.0.6. The release waits for all of them except `latest`, which is reported but not gating (a new Crystal release or a registry failure must not stop releases). `scripts/run_integration.py` no longer passes
  `--enable-debug-command` to a server older than 7 (6.2 does not know it). `.github/scripts/test_ci_matrix.py` fails when the
  matrix, `shard.yml`, the README, CLAUDE.md and `docs/reference/compatibility.md` disagree about the floors. Not tested, and
  not claimed: glibc, ARM, macOS, Crystal nightly, Redis 7.0 to 7.2, Redis Cluster and Sentinel. The README's stale
  "Crystal 0.34.0 or higher" is now "1.22.0 or newer".

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

### Added

- **Docs: the at-least-once guarantee is written down (#50).** [Delivery guarantees](docs/reference/delivery-guarantees.md)
  lists, per failure, what happens and whether the job body can run twice, each row citing its spec. The docs check
  (`scripts/check_docs.py`) fails when a cited spec file or spec name disappears.
- **The crash-recovery time is a setting.** `owner_ttl` (how long a heartbeat counts as alive, default 30 s, 1 s to 1 h)
  and `reaper_interval` (default 30 s, 100 ms up to `owner_ttl`) are `Configure` properties, `settings` keys in YAML and
  the environment variables `JOOBQ_OWNER_TTL` and `JOOBQ_REAPER_INTERVAL`. A process's jobs are back on their queue at
  most `owner_ttl + reaper_interval` after it was killed. The heartbeat now beats at a third of the TTL, at most every
  10 s. Values outside the range, or an interval longer than the TTL, raise `ConfigValidationError` when the YAML is
  loaded, from the environment (also for a value that is not a time span), and in `forge`. Defaults are unchanged.
  **Upgrade note:** `reaper_interval` was only the expired-job scan cadence. An existing `reaper_interval` above the
  default TTL does not stop the boot: the reaper runs every `owner_ttl` instead and a warning says so (only
  `owner_ttl` and `reaper_interval` both set, with the interval above the TTL, raise). Unset, the interval is
  `min(30 s, owner_ttl)`, so lowering `owner_ttl` alone works. Set both before `forge` (the reaper is built on first use);
  a very short interval scans every queue that often. `owner_ttl` must be the same on every process sharing a Redis, so
  change it with every process stopped. An assigned store keeps its own TTL unless the configuration set `owner_ttl`.

### Tests

- **A real SIGKILL proves Core crash recovery.** `scripts/crash_recovery_smoke.py` (run by CI) kills a worker process with
  12 jobs running, starts a second one inside the heartbeat TTL, and fails unless every job is re-run once by the second
  process within `owner_ttl + reaper_interval` (3 s + 1 s in the smoke). The assertions on the 0.5 shared
  processing list (`joobq:v1:processing:<queue>`, which 0.6 never writes to) in the shutdown and race specs now read
  `processing_depth`, so they can fail.

### Changed (breaking: two safer defaults, #55)

- **`allow_plaintext_payloads` now defaults to `false`.** It was `true`, so anyone with Redis write access could replace a
  sealed value of an `encrypted_property` with a plain one and the worker ran it. Now a worker that meets an unsealed
  value in such a property dead-letters the job without its payload. The flag only
  matters for job classes that use `encrypted_property`. **Upgrade note:** if you turned a property into an
  `encrypted_property` and jobs written before that are still in Redis, set `config.allow_plaintext_payloads = true` until they are
  drained, then remove it. The decision for 1.0 is `false`; a spec pins it.
- **The management API redacts secret-named job arguments (#55).** `GET /joobq/jobs/retrying`, `/joobq/jobs/dead` and the
  `job_data` of `/joobq/errors/recent`, `/by-type` and `/by-queue` returned every plain argument to the reader role. The
  value of an argument whose name contains one of `config.redacted_payload_keys` (default `password`, `passwd`, `pwd`,
  `passphrase`, `secret`, `token`, `api_key`, `authorization`, `bearer`, `jwt`, `credential`, `private_key`, `cookie`,
  `card_number`; case-insensitive, only letters and digits compared, so `privateKey` and `private.key` match, any depth) is now `[REDACTED]` in
  the answer, for every role. `auth` and `pass` are not in the list: they would hide `author` and `passenger_count`. The
  raw `original_job_data` of an unparseable job's dead-letter stub is always withheld, and text that cannot be parsed
  is withheld rather than shown. Stored jobs are untouched, so retries
  keep the real arguments. **A client that read those arguments through the API sees `[REDACTED]`.** Opt out with
  `config.redact_api_payloads = false`. Redaction goes by name: a secret under another name stays visible, so seal it
  with `encrypted_property` (the API never opens a sealed value). **Known limit: only argument values are redacted.** The
  error text the library records (`error_message`, `backtrace`, `error_cause` of `/joobq/errors/*`, and the job's `error` in
  the job listings) is shown as it is, so a secret an exception message quotes is visible to a reader; keep secrets out
  of exception messages (the library scrubs only the values of `encrypted_property` from error text).

### Changed (public API for 1.0, #43)

- **The frozen public API is listed** on [docs/reference/public-api.md](docs/reference/public-api.md), and
  `spec/public_surface_spec.cr` reads that page and fails when a listed member does not exist.
- **`JoobQ.enqueue(job)` is the way to enqueue a job instance** (`JoobQ.enqueue(queue_name, json)` is unchanged).
  `JoobQ.add(job)` is deprecated (`@[Deprecated]`, still works); it now takes a `JoobQ::Job` (it took any value).
  `Job.enqueue_at(span, ...)` is deprecated in favour of `Job.delay(for: span, ...)` (same result, it now calls it).
  The nine `JoobQ.load_*` wrappers and `JoobQ.find_config_file` are deprecated. They return a `Configure` and install
  nothing, so they are not the same as `JoobQ.initialize_config` and `JoobQ.initialize_config_with(:file | :yaml | :string |
  :sources | :cli_args | :env_overrides | :hybrid)`, which load **and install** the configuration, return `nil` and do nothing
  once a configuration is set. A caller that uses the returned object calls the frozen `JoobQ::Configure.load_from_yaml`, `.load_hybrid`,
  `.load_from_yaml_sources` or `.load_from_cli_args` and passes the result to `JoobQ.set_config` (`load_from_string` and
  `find_config_file` have no such replacement). They are
  removed no sooner than two minor releases and 90 days after the release that deprecates them (the deprecation rule of the
  [compatibility page](docs/reference/compatibility.md)).
  Known callers outside this repository: `JoobQ.add` is called by joobqui's `examples/conformance/crystal/worker.cr` (line 500) and
  `bench/sdk-gateway/crystal/bench.cr` (line 48), which only get a compile warning until they move to `JoobQ.enqueue`; the azu docs
  (`docs/how-to/jobs/background-jobs.md`) mention `enqueue_at`. Nothing in joobqui, joobq-pro or `azu_cli`'s `src` calls the other deprecated members; `azu_cli`'s joobq initializer uses
  `initialize_config_with(:file, ...)`, which stays.
- **Internal helpers are marked `:nodoc:`:** `JoobQ.reset_config` (JoobQUI calls it), `JoobQ::RedisStore#redis` (JoobQ Pro and
  JoobQUI call it), `JoobQ::MiddlewarePipeline`, `Configure#middleware_pipeline`, `JoobQ::YamlConfigLoader`
  and `Job#__secret_values`. They keep working; they are not part of the frozen API.
- **`JoobQ.scheduler` is removed.** It called `Scheduler.instance`, which does not exist, and compiled only because nothing called
  it; a caller now fails to compile instead of at the first call. Build schedulers with `config.scheduler { ... }`.

### Fixed

- **`register_job` outside the `JoobQ` namespace compiled to an unknown constant** (`QueueFactory`); it now names
  `::JoobQ::QueueFactory`, so `JoobQ.configure { register_job MyJob }` works from application code (#43).

- **`GET /joobq/jobs/retrying` listed nothing (#55).** It compared the job status with `"Retrying"`, but jobs serialize it as
  `"retrying"`, so the route always answered an empty list. The comparison now ignores case.

- **The durable (Delivery) runtime starts on Redis 6.2.** Its durability check sent one `CONFIG GET` with three
  names, which only Redis 7.0 and later accept, so on 6.2 (the stated floor) `Delivery::Runtime.new` failed with
  "ERR Unknown subcommand or wrong number of arguments for 'GET'" instead of checking. It asks for each setting in its own
  call. Found by running the suite on Redis 6.2.24 (eleven delivery and error-code specs failed in a local run); the new 6.2 CI legs keep it covered.
- **`Configure#setup_schedulers_from_config` is removed (refs #42).** It was public and documented with an example, but
  its cron and recurring blocks only logged "Would enqueue ..." at debug level, so a YAML `schedulers:` entry never ran
  and nothing said so. JoobQ Core still parses the section into `config.scheduler_configs` (JoobQUI's schedule catalog
  and worker read it) and never fires it; to run a schedule from your own code use the scheduler DSL
  (`config.scheduler { cron "..." { ... } }`). A caller of the removed method now fails to compile instead of scheduling
  nothing. Whether Core should ever fire YAML schedulers is still open on #42.
- **`POST /joobq/jobs` fails loudly instead of answering 201 for a job it dropped (#48).** The route kept its shape
  (`{queue, job_type, data}`) but fed the whole body to the lenient `Queue#add`, which parsed it as the job itself,
  swallowed the error and returned nothing, so the client got `201` with an empty `job_id` and no job. It now uses the
  strict `Queue#add!` with `data` as the job's JSON: a `data` that does not fit the job class, or a `job_type` that is
  not the queue's, answers `422` and enqueues nothing; `job_id` is the stored job's id. The HTML escaping of `data`
  (`&` became `&amp;`) is gone: arguments reach `perform` unchanged. `retries` and `delay` (validated before, ignored)
  are applied (`retries` also sets `max_retries`; `delay` 0 enqueues at once); `priority` is still validated and has no effect. `data` is the job's own JSON, so it may not carry the job's bookkeeping fields `jid`, `queue`, `retries`, `max_retries`, `expires`, `status`, `v` or `error`: one of them answers `422` naming the key (they would walk around the bounds on `retries` and `delay`). The route stays deprecated.
- **Management API list limits are validated and capped (#54).** `GET /joobq/jobs/retrying?limit=N` and
  `/joobq/jobs/dead?limit=N` used `.max` where a cap was meant, so a reader token could make Redis return an unbounded
  number of entries, and `?limit=abc` or `?limit=-1` raised out of the handler. `limit` must now be an integer from 1 to
  100 (`APIValidation::MAX_LIST_LIMIT`, the bound `/joobq/errors/recent` already had), else `400` with the reason; the
  routes read a fixed window of Redis whatever the limit. **A client that sent `limit` above 100 now gets `400`.** Known limit: there is no offset, and with `?queue=X` the dead-letter route filters the 100 newest dead letters, so older dead jobs of `X` behind other queues' entries are not listed (`JoobQ::DeadLetterQueue.new.page(offset: 0, limit: 50, queue: "X")` pages through all of them).
- **The `timezone` setting applies, and no longer changes the process zone (#44).** `config.time_location = "UTC"`
  (also YAML `timezone` and `JOOBQ_TIMEZONE`) used to set the process-wide `Time::Location.local` and never store the
  zone, so `config.time_location` and every `Scheduler.new` default stayed `America/New_York`. It now stores the zone for
  JoobQ's own cron computations and leaves `Time::Location.local` alone; it also takes a `Time::Location`. Merging YAML
  sources keeps the zone of the last source that set one. **Upgrade note: cron schedules shift.** Until now every
  `config.scheduler { cron ... }` pattern ran in New York time whatever `timezone` said. A deployment whose
  configuration says another zone now fires in that zone: `config/joobq.production.yml` and `config/joobq.test.yml`
  say `UTC`, so their cron patterns fire in UTC and the job key changes from `"<pattern>:America/New_York"` to
  `"<pattern>:UTC"`. The `azu_cli` joobq initializer template (`config.time_location = "UTC"`) now yields UTC cron times
  too. Check each cron pattern against the zone you configured, or set `timezone: "America/New_York"` to keep the old
  times. Code that relied on the process zone changing must set `Time::Location.local` itself.
- **A process frozen past the heartbeat TTL no longer settles jobs another process reclaimed.** After `owner_ttl` of
  silence recovery moves a process's jobs back to their queue; when that process woke up it still completed its copies,
  and every job counted twice (`joobq:v1:stats:completed` = 20 for 10 jobs) while a failure could schedule a second
  retry or a second dead letter. A claim is now the copy in the process's own processing list, and the settlement
  scripts act only while they still hold it: completion and cleanup (`RedisStore#mark_job_completed`, `#cleanup_job`) remove
  the copy and count in one step, and inside a worker `move_to_retry`, `move_to_dead_letter` and `mark_as_dead` write only
  if the copy is still there (and leave its removal to the cleanup). A refused claim makes its execution inert
  (`InFlight.fence`, as for an abandoned one), logs `Another process reclaimed this job after this process's heartbeat
  lapsed`, and counts nothing; a heartbeat that finds the previous one older than the TTL logs `This process's heartbeat
  lapsed`. The job body still ran twice: delivery stays at-least-once. Behaviour changes: `mark_job_completed` and
  `cleanup_job` count only when they remove the copy (they answer `true` either way), and they remove one copy, not
  every identical one.
  `RedisStore#claim_held?` reads whether a claim is still held. A retry or dead letter inside a worker is one script
  that also takes the claim copy off the list and counts the job (the worker skips its cleanup), so a cleanup lost to an
  outage leaves nothing to re-drive; `RedisPipeline#cleanup_jobs_batch` settles each job the same fenced way.
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

## 0.7.0

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

## 0.6.1

### Changed

- **Workers no longer busy-poll for jobs.** Each queue now runs one dispatcher fiber on a dedicated blocking
  connection that claims the head job with `BLMOVE` and hands it (plus a pipelined batch top-up) to the worker
  fibers over an in-process channel. Idle workers block on that channel instead of polling Redis, so idle Redis
  load and the number of Redis connections no longer grow with the worker count, and a job on an idle queue is
  picked up in sub-millisecond time (previously up to the 100 ms poll). Claims still land in this process's own
  processing list, so FIFO order and crash recovery are unchanged; blocking connections are O(active queues). A
  non-Redis store, or a `Worker` run outside `Queue#start`, keeps the previous self-claiming behaviour.

## 0.6.0

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
