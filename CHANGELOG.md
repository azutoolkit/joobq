# Changelog

## 0.6.0 (MINOR)

### Changed

- **Queues are first in, first out.** Producers still `RPUSH` to the tail of a queue; workers now claim from the head
  (`BLMOVE queue processing LEFT LEFT` for a single claim, pipelined `LMOVE ... LEFT LEFT` for a batch), so jobs run
  in the order they were enqueued. Until 0.5.x workers claimed from the tail (`BRPOPLPUSH`/`RPOPLPUSH`) and the
  newest job ran first. Delayed and retried jobs still join the tail when they are due, and so do dead-letter replays.
  `RedisStore#list_jobs` (and `Queue#jobs`) list the next job to run first.
- **Redis 6.2 or newer is required** (`BLMOVE` and `LMOVE`). CI tests Redis 7.4 and 8.0. A queue on a server
  without `LMOVE` refuses to start (`ArgumentError` from `Queue#start`) instead of failing every claim.
- **Jobs abandoned at shutdown run next.** `JoobQ.shutdown` puts the jobs it gives up on back at the head of their
  queue, in the order this process took them (`RedisStore#requeue_many_from_processing`; jobs still settling a
  failure at the deadline are put back a moment later, in front of them). Another running process can claim them at
  once, while this process's fibers may still be finishing them: jobs must be safe to run twice. A job bounced for missing
  encryption keys still goes to the tail (`requeue_from_processing`), so it does not come straight back.

### Fixed

- **Crash recovery returns every stranded job.** `Queue#start` (and `POST /joobq/queues/:name/reprocess`) call
  `move_job_back_to_queue`, which moved at most one job from the processing list back to the queue and blocked for
  half a second when there was none. It now moves every job in the processing list back to the head of the queue in
  one atomic Lua script, in the order they were claimed, and returns at once when the list is empty. The new
  `RedisStore#recover_processing` returns how many jobs it moved.

### Upgrading

- During a rolling upgrade, workers on 0.5.x take the newest job and workers on 0.6 the oldest, so order is mixed
  until every worker runs 0.6. Mixing versions loses no job: both claim into the same processing list in the same
  layout, and 0.6's recovery reads what 0.5.x left there (but see the next point about overlapping processes).
- Recovery still has no per-process ownership check, and it now moves the whole processing list, not one job. A 0.6
  process that starts while another process is working on the same queue puts all of that process's running jobs
  back, so they run twice, and when the original run finishes it removes the job from the processing list
  (`LREM`), also the new claim's entry, so a crash of the second run after that loses the job. The same holds for
  `stop!` followed by `start` in one process while claimed jobs are still running, and for
  `POST /joobq/queues/:name/reprocess` on a live system. Stop the old workers first (`SIGTERM` drains them), call
  `reprocess` only when no worker is running, and make the jobs safe to run twice.
