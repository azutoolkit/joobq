---
description: Choose delayed admission, a local recurring callback, or a durable Pro schedule.
---

# Schedule jobs

First choose what needs to survive a process restart. A delayed job is stored in Redis. Core recurring and cron registrations are process-local loops. Pro workflow schedules add persisted scheduling and leader coordination.

| API | Execution behavior |
| --- | --- |
| `Job.delay(for: ...)` | Stores one job for later queue admission; workers and delayed-job processing must be running |
| `Job.schedule(every: ...)` / `scheduler.every` | Immediately starts a local loop calling the same job instance's `perform`; bypasses queue middleware |
| `scheduler.cron` | Runs your callback on the cron schedule in that process; enqueue explicitly inside the callback for queued processing |
| Pro workflow schedules | Persisted workflow starts with overlap, catch-up, and backfill policies |

## Keep recurring callbacks small

A Core recurring callback runs directly, may overlap a previous invocation, and logs failures rather than applying queue retries or DLQ handling. It starts on registration, with the first invocation immediately eligible. Use it to enqueue a fresh job if you need normal worker processing.

This complete **Core v0.5.1** example owns both the local recurring producer and the queue workers in one process:

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

```sh
crystal run src/report_scheduler.cr
```

Expect `Generated report 42` shortly after startup, then about once per minute. Stop with Ctrl-C. The output only demonstrates scheduling and dispatch; replace the formatter with idempotent report generation.

Own this recurring registration in one process. Restarting it resets the local schedule and can run immediately again. Registering it twice creates two loops; there is no distributed leader, persisted catch-up, or deduplication for Core recurring callbacks. Stopping a scheduler prevents future callbacks but does not join every already-spawned callback fiber, so keep admission callbacks short.

## Use cron when wall-clock timing matters

Inside the same Core worker's configuration block, after defining `GenerateReportJob`, this alternative admits a report at 09:00 UTC each day:

<!-- illustrative: alternative scheduler registration inside JoobQ.configure -->
```crystal
scheduler(Time::Location.load("UTC")) do
  cron("0 9 * * *") do
    GenerateReportJob.enqueue(report_id: 42_i64)
  end
end
```

Choose one registration owner and an explicit timezone. Cron registrations also start their local loops when registered, so keep them out of an initializer loaded by status tools.

{% hint style="warning" %}
The baseline YAML `setup_schedulers_from_config` path logs scheduling intent instead of admitting the configured jobs. Use the executable programmatic APIs above; do not assume a YAML scheduler entry proves work will run.
{% endhint %}

## Use a durable workflow schedule when needed

For persisted workflow starts and explicit overlap/catch-up policy, use [Pro workflow schedules](../pro/workflows.md#schedules-and-deployments). At least one Pro worker must have its workflow scheduler enabled (`scheduler: true`, the default). The production worker example deliberately disables it; timers and workflow deadlines still work through the reconciler.

**Next:** [Worker lifecycle](workers.md) and [failure recovery](handle-failures.md).
