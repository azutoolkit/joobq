---
description: Recover transient failures without turning replay into duplicate side effects.
---

# Retries and dead letters

A raised exception enters the retry middleware. Core's default budget is **three retries**, allowing the initial attempt plus three further attempts. Backoff starts at one second, doubles by retry attempt, and is capped at one hour in the baseline implementation. It is not a promise that a job starts at exactly that time.

The remaining budget is carried with the serialized job. Every failure is either scheduled for retry once or dead-lettered; exhausted jobs move to the DLQ with failure context. A per-job retry lock (`joobq:retry_lock:<jid>`) holds the attempt it scheduled, so a second handler of the same failure backs off while the job's next failure is retried as usual. `dead_letter_ttl` defaults to seven days, but the documented Redis implementation stores entries in a sorted set without applying that TTL or automatically pruning by age. Do not assume records disappear after seven days. Monitor growth and implement a reviewed retention/export policy using the DLQ APIs; the DLQ is not a backup or a permanent audit guarantee.

## Stop retrying a permanent failure

Raise `JoobQ::NonRetryableError`, or a subclass, when running the job again cannot succeed: a declined card, a deleted record, input that will never validate. The job goes to the DLQ at once, whatever retries it has left, and `perform` is not called again.

<!-- illustrative: a job class with an application-defined declined? check -->
```crystal
class ChargeJob
  include JoobQ::Job

  class Declined < JoobQ::NonRetryableError
  end

  property order_id : Int64

  def initialize(@order_id)
  end

  def perform
    raise Declined.new("card declined for order #{order_id}") if declined?(order_id)
  end
end
```

Other exceptions are retried while budget remains, whatever their class.

## What a dead letter records

The stored job keeps `"status": "dead"` and an `error` object describing the last failure:

| Field | Content |
| --- | --- |
| `error_class` | The exception's class, such as `ChargeJob::Declined` |
| `error_type` | Its category: `non_retryable_error`, `validation_error`, `connection_error`, `unknown_error`, ... |
| `message` | The exception's message, at most 4 KiB |
| `backtrace` | The first 20 lines of the backtrace, newline-separated, at most 8 KiB |
| `cause` | The message of the exception's cause, or an empty string |
| `failed_at` | When it failed (RFC 3339) |
| `retry_count` | The attempt that failed, 0 being the first run |
| `system_context` | Worker, queue and host details |

Values of `encrypted_property` fields are removed from the message and backtrace. `DeadLetterQueue#page` also returns the message alone as each entry's `error`. Re-driving an entry clears the error and restores the full retry budget.

## Inspect before replaying

Inside an Azu application configured for JoobQ:

```sh
azu jobs:dlq --queue orders --limit 20 --json
azu jobs:retry --queue orders --limit 1 --dry-run
```

Fix the failure and verify the preview's target before executing a replay. The CLI prompts interactively; its `--force` flag is the explicit automation path. In `azu joobq`, select a DLQ entry and use `r`, then `y`, to confirm that selected replay.

[Screenshot: The azu joobq dead-letter view with one failed order job selected, showing its ID, queue, failure time, redrive eligibility, and the replay confirmation prompt with sensitive payload values hidden.]

## Know what can be replayed

Some malformed or withheld payloads cannot be reconstructed into a job. Honor the native `redrivable` result; do not hand-edit Redis entries to force them through. Keep the job class available and compatible with old payloads during deployments.

An atomic queue transition prevents competing operators from moving the same stored member twice. It does **not** make an external payment or email exactly once. A worker may have completed the side effect before losing its acknowledgement. Use [idempotency](../how-to/write-idempotent-jobs.md) for that boundary.

{% hint style="warning" %}
A connection error can mean an unknown Redis outcome. Do not blindly enqueue again with a new identity or repeat a bulk replay. Reconcile the original job or receipt first.
{% endhint %}

**Next:** [Troubleshooting](../how-to/troubleshoot.md).
