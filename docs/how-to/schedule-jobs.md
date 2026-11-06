---
description: Run one job later, or enqueue a job at a fixed interval, so that it is processed by the queue's workers.
---

# Delay and schedule jobs

*How-to · Core*

## Prerequisites

- A job class registered on a queue, and a worker process running `JoobQ.forge`: the delayed set is moved to the queue by that process once a second.

## Delay one job

Call `delay` (or `enqueue_at`) with a `Time::Span` and the job's arguments; it returns the job's id:

<!-- illustrative: ProcessOrderJob from the first tutorial -->
```crystal
jid = ProcessOrderJob.delay(for: 5.minutes, order_id: 42_i64)
```

The job waits in `joobq:delayed_jobs` and joins its queue at the first check after it is due. Both methods take a span, not a `Time`: for "at 09:00", compute the span yourself.

## Enqueue a job at a fixed interval

1. Write a small job whose `perform` only enqueues the real job.
2. Call `schedule(every:)` on it in one process. It calls `perform` at once and then every interval, in that process only.

{% code title="src/report_scheduler.cr" %}
<!-- example: core/scheduled_jobs.cr -->
```crystal
require "joobq"

struct GenerateReportJob
  include JoobQ::Job
  @queue = "reports"
  getter report_id : Int64

  def initialize(@report_id : Int64)
  end

  def perform
    puts "Generated report #{report_id}"
  end
end

# The recurring callback only admits work. Queue workers perform the report.
struct EnqueueReportJob
  include JoobQ::Job
  getter report_id : Int64

  def initialize(@report_id : Int64)
  end

  def perform
    GenerateReportJob.enqueue(report_id: report_id)
  end
end

JoobQ.configure do |config|
  config.rest_api_enabled = false
  config.worker_batch_size = 1
  queue "reports", 2, GenerateReportJob
end

# Starts immediately; own this registration in one scheduler process only.
EnqueueReportJob.schedule(every: 1.minute, report_id: 42_i64)
JoobQ.forge
```
{% endcode %}

## Verify

Output of `crystal run src/report_scheduler.cr` (log lines omitted):

```
Generated report 42
```

The report ran on the `reports` queue's worker, so it has the queue's retries and dead letters.

## See also

- [Run cron and recurring jobs](run-cron-and-recurring-jobs.md): wall-clock patterns.
- [Cron and recurring jobs](../explanation/delayed-and-recurring-jobs.md): which schedules go through a queue.
- Pro workflow schedules (overlap, catch-up, time zone): [Workflows and sagas](../explanation/durable-workflows.md).
