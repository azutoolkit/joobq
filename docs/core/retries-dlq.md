---
description: Recover transient failures without turning replay into duplicate side effects.
---

# Retries and dead letters

A raised exception enters the retry middleware. Core's default budget is **three retries**, allowing the initial attempt plus three further attempts. Backoff starts at one second, doubles by retry attempt, and is capped at one hour in the baseline implementation. It is not a promise that a job starts at exactly that time.

The remaining budget is carried with the serialized job. Exhausted jobs move to the DLQ with failure context. Retention is finite; the default dead-letter TTL is seven days. Treat the DLQ as a recovery queue, not a permanent audit archive.

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

An atomic queue transition prevents competing operators from moving the same stored member twice. It does **not** make an external payment or email exactly once. A worker may have completed the side effect before losing its acknowledgement. Use [idempotency](../best-practices/idempotency.md) for that boundary.

{% hint style="warning" %}
A connection error can mean an unknown Redis outcome. Do not blindly enqueue again with a new identity or repeat a bulk replay. Reconcile the original job or receipt first.
{% endhint %}

**Next:** [Troubleshooting](../best-practices/troubleshooting.md).
