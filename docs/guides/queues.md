---
description: Connect a concrete job type to the right queue and execution capacity.
---

# Configure queues

A legacy queue consumes one concrete job type. Producers choose a queue through the job's `@queue`; the worker must register that same queue name and type. Sharing Redis alone does not establish this mapping.

## Register before starting workers

For standalone **Core v0.5.1**, load `ProcessOrderJob` from the [quick start](../quick-start/README.md), then configure it:

<!-- illustrative: shared initializer after requiring ProcessOrderJob -->
```crystal
JoobQ.configure do |config|
  config.rest_api_enabled = false
  config.worker_batch_size = 1
  queue "orders", 2, ProcessOrderJob
end
```

With a batch size of one, the two worker loops can hold two jobs in flight. With the default batch size of ten, the same two workers can hold twenty. A handler can create additional fibers of its own, so this is not an application-wide concurrency limit.

For **Pro v0.2.2's pinned Core**, use its compatible factory registration for legacy jobs:

<!-- illustrative: shared initializer after requiring ProcessOrderJob, on Pro's pinned Core -->
```crystal
JoobQ::QueueFactory.register_job_type(ProcessOrderJob)
JoobQ.configure do |config|
  config.rest_api_enabled = false
  config.worker_batch_size = 1
  config.queue_configs["orders"] = {
    job_class_name: "ProcessOrderJob", workers: 2, throttle: nil,
  }
end
```

Do not apply both alternatives. Pro workflow activities are registered through `Workflows::Worker#register`, which creates their transport queues; they are not `ProcessOrderJob` registrations.

## Separate workload classes

Use different queue names for different concrete job types and for workloads needing separate operational control. For example, report generation should not occupy every worker needed by order notifications. Give each producer and consumer the same Redis database, job definitions, and queue mapping.

## Inspect and pause

In an Azu app configured with the [documented CLI](../pro/management.md):

```sh
azu jobs:status --queue orders --json
azu jobs:pause --queue orders
azu jobs:resume --queue orders
```

Pause/resume require confirmation. Pausing stops further claims; jobs already claimed can still execute, and producers can continue enqueueing. This is a shared pause state, not a kill switch for external effects.

Before adding replicas or overlapping deployments, read the [legacy startup recovery limit](../best-practices/recovery.md#know-the-legacy-startup-recovery-limit). An empty ready queue is not proof that every claimed job completed.

**Next:** [Run workers](workers.md) and [tune concurrency](../configuration/concurrency.md).
