---
description: Tune work in flight without confusing fibers, threads, and connection counts.
---

# Tune concurrency and shutdown

*How-to · Core*

## Prerequisites

- A representative workload ([Measure performance](measure-performance.md)).

## Steps

1. Set the queue's worker count and `worker_batch_size`; a process runs at most workers times batch size jobs at once on that queue.
2. Set `REDIS_POOL_SIZE` for the total of all workers in the process.
3. To try several runtime threads, build with `-Dpreview_mt` and set `CRYSTAL_WORKERS` to the CPUs allocated to the process:

```sh
mkdir -p bin
crystal build src/worker.cr --release -Dpreview_mt -o bin/worker
CRYSTAL_WORKERS=4 ./bin/worker
```
4. Give shutdown enough time: `JoobQ.forge(shutdown_timeout: ...)` (default 15 seconds), or `azu jobs:worker --shutdown-timeout 25`, and a supervisor stop timeout longer than that.
5. If you call `JoobQ.forge(trap_signals: false)`, call `JoobQ.shutdown` yourself and read `JoobQ.abandoned_jobs` afterwards; for Pro, call `JoobQPro.shutdown` first.

## Verify

- Send SIGTERM while jobs run: the process exits `0` when all finished, `3` when some were put back on their queue.
- Throughput rose and downstream latency stayed within your limit at the new setting.

## See also

- [Workers and concurrency](../explanation/workers-and-concurrency.md)
