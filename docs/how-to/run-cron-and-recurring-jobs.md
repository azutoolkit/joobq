---
description: Run work on a cron pattern or an interval so that each run is a queued job with retries.
---

# Run cron and recurring jobs

*How-to · Core*

## Prerequisites

- A Core project with a job class for the work, registered with `queue` (see [Configure queues](configure-queues.md)).
- One process that owns the schedule: Core's cron and interval loops run in the process that registers them, and two processes would both fire.

## Steps

1. In `JoobQ.configure`, open a `scheduler` with the time zone the pattern means, and register a `cron` block that only enqueues the job:

<!-- example: core/cron_job.cr -->
```crystal
require "joobq"

struct SendDigestJob
  include JoobQ::Job

  @queue = "digests"
  @@sent = Atomic(Int32).new(0)
  getter list : String

  def initialize(@list : String)
  end

  def self.sent
    @@sent.get
  end

  def perform
    @@sent.add(1)
    puts "Sent the #{list} digest"
  end
end

JoobQ.configure do |config|
  config.rest_api_enabled = false
  queue "digests", 1, SendDigestJob

  # Six fields: the first is seconds. The block only enqueues, so the job keeps its retries.
  scheduler(Time::Location.load("UTC")) do
    cron("*/2 * * * * *") { SendDigestJob.enqueue(list: "weekly") }
  end
end

spawn { JoobQ.forge(trap_signals: false) }
until SendDigestJob.sent == 2
  sleep 100.milliseconds
end
JoobQ.shutdown(5.seconds)
puts "cron enqueued 2 digests"
```

   A five-field pattern (`"0 9 * * 1-5"`) fires on minutes; a six-field pattern's first field is seconds.

2. For a fixed interval instead, use the DSL's `every 10.minutes, EnqueueDigestJob, list: "weekly"` or `EnqueueDigestJob.schedule(every: 10.minutes, list: "weekly")`. Both call the given job's `perform` directly in this process, so make it a small job whose `perform` enqueues the real one.

3. Start the process with `JoobQ.forge` and run it in exactly one replica.

## Verify

Output of `LOG_LEVEL=fatal crystal run cron_job.cr`:

```
Sent the weekly digest
Sent the weekly digest
cron enqueued 2 digests
```

Each run reached the `digests` queue, so a failing run is retried and dead-lettered like any other job.

## See also

- [Cron and recurring jobs](../explanation/delayed-and-recurring-jobs.md): which schedules go through a queue.
- [Delay and schedule jobs](schedule-jobs.md): one job at a later time.
