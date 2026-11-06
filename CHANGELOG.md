# Changelog

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
