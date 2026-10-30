---
description: Separate a future job from recurring scheduling and durable workflow schedules.
---

# Delayed and recurring jobs

A delayed job is one job that becomes eligible later. A recurring job creates work repeatedly. Neither guarantees an exact wall-clock start: queue depth and available workers still matter.

With `ProcessOrderJob` from the Quick Start, the instance below schedules one order. The complete fixture includes the job definition and queue registration.

<!-- illustrative: insert after ProcessOrderJob and queue registration from Quick Start -->
```crystal
ProcessOrderJob.delay(for: 5.minutes, order_id: 42_i64)
```

Core also exposes `schedule(every: ...)` and the scheduler DSL for interval or cron work. Do not register the same recurring producer in every application process unless duplicate scheduling is intended; audit the installed scheduler's ownership behavior first.

## Choose by the ownership you need

| Need | API family |
| --- | --- |
| Enqueue one job later | Core delayed job |
| Repeated work owned by your configured scheduler process | Core recurring/cron scheduler |
| Durable workflow starts, leader lease, overlap and catch-up rules | Pro workflow schedules |

Pro schedules support explicit overlap policies, catch-up windows, and timezones. A deterministic run identity coordinates competing schedulers for one fire time. Activity effects still require idempotency.

**Next:** [Workflow schedules](../pro/workflows.md#schedules-and-deployments).
