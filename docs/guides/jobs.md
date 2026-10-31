---
description: Write a typed job, admit work, and keep retries safe.
---

# Write and enqueue jobs

A Core job is a Crystal type that includes `JoobQ::Job` and implements `perform`. Its serializable properties carry the input; the worker reconstructs that type before running it. Start with the complete [first job](../quick-start/README.md), or the [thin-job example](../design-patterns/thin-jobs.md) when you want a separately testable business service.

## Choose how to run it

With `ProcessOrderJob` and the configuration from the quick start:

<!-- illustrative: after loading the ProcessOrderJob definition and shared configuration -->
```crystal
ProcessOrderJob.enqueue(order_id: 42_i64)
ProcessOrderJob.delay(for: 5.minutes, order_id: 43_i64)
ProcessOrderJob.perform(order_id: 44_i64)
```

These are three separate operations:

| Call | What happens |
| --- | --- |
| `enqueue` | Serializes a new job and writes it to its Redis queue |
| `delay` | Stores a new scheduled job; a running delayed-job scheduler promotes it when due |
| `perform` | Runs immediately in the calling process, without Redis admission or queue middleware |

`enqueue` returns the job ID as a string; `delay` returns a `UUID`. Neither is a completion receipt. Legacy jobs have no client result-wait API; record business results in your application or observe worker events. Pro workflows have their own [client](clients.md).

## Keep payloads small and stable

Pass record IDs and a business idempotency key. Avoid open connections, credentials, and large documents. Changing a property's name or type can break jobs already waiting in Redis, so test deserialization of old payloads before deployment.

A job's queue, retry budget, and expiration are captured when it is constructed. Keep its `@queue` consistent with the registered consumer. The default retry budget is three further attempts; raising an exception lets queue middleware apply it. Catching and swallowing a failure inside `perform` makes it look successful to that middleware.

The default job expiration is three days from construction, not from the delayed start time. Set an appropriate expiration when scheduling far into the future. `config.timeout` does not interrupt arbitrary handler code; put deadlines on your HTTP and database clients.

## Track the business effect

A failed acknowledgment can follow a successful write. Keep the original identity, reconcile the outcome, and make the handler [idempotent](../best-practices/idempotency.md). Creating a new job does not deduplicate the business operation.

**Next:** [Configure queues](queues.md), [schedule work](scheduling.md), or [inspect failures](handle-failures.md).
