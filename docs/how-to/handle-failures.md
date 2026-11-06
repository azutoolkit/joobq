---
description: Choose retries, compensation, and replay based on what actually happened.
---

# Set retries and handle failures

*How-to · Core · Pro*

## Prerequisites

- A job or workflow activity that calls something that can fail.

## Steps

1. Set the Core retry budget with `config.retries` (0 to 100, default 3 retries after the first run), or per job with its `retries` and `max_retries` properties.
2. For a failure that retrying cannot fix (a declined card, a deleted record), raise `JoobQ::NonRetryableError` or a subclass; in a workflow activity, `JoobQPro::Workflows::NonRetryableError`.
3. In a workflow, set a retry policy on the step; `attempts:` counts the first attempt:

<!-- illustrative: inside a workflow block with an application-defined ChargeCard activity -->
```crystal
step :charge, ChargeCard,
  input: input,
  timeout: 10.seconds,
  retry: retry_policy(attempts: 3, initial: 1.second, maximum: 10.seconds)
```
4. After fixing the cause, inspect the dead letters and preview a replay before running it:

```sh
azu jobs:dlq --queue orders --limit 20 --json
azu jobs:retry --queue orders --limit 1 --dry-run
```
5. For a workflow, inspect the run with `client.describe(id)` and `client.history(id)` instead of replaying its activity jobs.

## Verify

- `azu jobs:dlq --queue orders --json` lists the failed jobs with their errors.
- After the replay, the job's effect is there once and the entry is gone from the dead letters.

## See also

- [Retries, backoff and the DLQ](../explanation/retries-and-dead-letters.md)
- [Reliability and recovery](../explanation/reliability-and-recovery.md)
