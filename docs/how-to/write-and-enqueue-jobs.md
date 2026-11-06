---
description: Write a typed job, admit work, and keep retries safe.
---

# Write and enqueue jobs

*How-to · Core*

## Prerequisites

- A Core project with a queue registered for the job ([Configure queues](configure-queues.md)).

## Steps

1. Define the job: a struct that includes `JoobQ::Job`, sets `@queue` to its queue's name, declares its input as typed properties, and implements `perform`. See `ProcessOrderJob` in [Your first background job](../tutorials/first-background-job.md).
2. Pass record ids and a business key, not whole records, connections or credentials.
3. Run it in one of three ways:

<!-- illustrative: after loading the ProcessOrderJob definition and shared configuration -->
```crystal
ProcessOrderJob.enqueue(order_id: 42_i64)
ProcessOrderJob.delay(for: 5.minutes, order_id: 43_i64)
ProcessOrderJob.perform(order_id: 44_i64)
```
   - `enqueue` writes it to its queue and returns the `jid` as a `String`;
   - `delay` stores it in the delayed set and returns the `jid` as a `UUID`;
   - `perform` runs it now, in this process, with no queue and no retries.
4. Let failures raise: a `perform` that rescues and swallows an error looks successful to the retry middleware.
5. For a job delayed by more than three days, set its `expires` further out: the default is three days from construction.

## Verify

The worker's log shows `Job completed successfully` with the `jid` that `enqueue` returned.

## See also

- [Jobs and payloads](../explanation/job-lifecycle.md): the fields a job carries and its states.
- [Write idempotent jobs](write-idempotent-jobs.md)
