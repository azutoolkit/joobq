---
description: Give each job type its queue and worker count, and keep urgent work on a queue of its own.
---

# Configure queues and worker counts

*How-to · Core*

## Prerequisites

- The job classes, loaded before `JoobQ.configure` runs (in a file the web process and the worker both require).

## Steps

1. Declare one queue per job type with its worker count (1 to 1000), and set `@queue` in the job to the same name:

   <!-- illustrative: shared initializer after requiring the job classes -->
   ```crystal
   JoobQ.configure do |config|
     config.rest_api_enabled = false
     config.worker_batch_size = 2 # jobs each worker holds at once (default 10)
     queue "emails-urgent", 4, SendPasswordResetJob
     queue "emails-bulk", 1, SendNewsletterJob
   end
   ```

2. Give urgent work its own queue and more workers: Core has no priority field, and a queue serves its newest waiting job first.
3. Add a fourth argument to space out starts in this process, for example `{limit: 10, period: 1.second}`.
4. Size `REDIS_POOL_SIZE` (default 500) for the total of all workers in the process.

## Verify

- Start the worker. Its log has one `JoobQ starting <name> queue...` line per queue.
- In an Azu application: `azu jobs:status --queue emails-urgent --json`.
- In JoobQUI: **Queues** shows each queue with its worker count (`joobqui_queue_concurrency` in `/metrics`).

The most jobs one process runs at once on a queue is workers times `worker_batch_size`: here 8 for `emails-urgent` and 2 for `emails-bulk`.

## See also

- [Queues and priorities](../explanation/queues-and-workers.md)
- [Tune concurrency and shutdown](tune-concurrency-and-shutdown.md)
- [Pause queues during an outage](pause-queues-during-an-outage.md)
