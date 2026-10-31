---
description: Choose retries, compensation, and replay based on what actually happened.
---

# Handle failures

Start with the failed operation, not the retry button. Did it fail before doing any work, or could the external effect already have happened?

| Situation | Useful response |
| --- | --- |
| Temporary dependency outage | A bounded retry with a stable business identity |
| Invalid input or a permanent business rejection | Stop retrying; return or record an actionable failure |
| A later workflow step fails after an earlier effect | Run a compensating operation where one exists |
| Redis disconnects before an acknowledgment | Reconcile the original identity; the outcome may be unknown |

## Set a workflow retry budget

The activity below is application code. Keep external calls idempotent and set their own client timeouts.

<!-- illustrative: inside a workflow block with an application-defined ChargeCard activity -->
```crystal
step :charge, ChargeCard,
  input: input,
  timeout: 10.seconds,
  retry: retry_policy(attempts: 3, initial: 1.second, maximum: 10.seconds)
```

In the DSL, `attempts: 3` includes the first attempt. Core's `config.retries = 3` means the initial attempt plus three retries. These are different settings. An activity may raise `JoobQPro::Workflows::NonRetryableError` for a permanent failure. A timeout does not cancel an external HTTP request or reverse a payment.

## Inspect before replay

In a configured Azu app using the [documented CLI](../pro/management.md):

```sh
azu jobs:dlq --queue orders --limit 20 --json
azu jobs:retry --queue orders --limit 1 --dry-run
```

These inspect legacy queue failures. A Pro workflow has its own run history: inspect it through `client.describe(id)` and `client.history(id)`. Do not treat a workflow activity's transport job as an independent order to replay.

Before retrying, repair the cause, verify whether the effect already happened, and preserve its business idempotency key. Start with one reviewed item. Watch completed work and error rates before expanding recovery.

**Next:** [Sagas](../design-patterns/sagas.md), [dead-letter handling](../core/retries-dlq.md), or [recovery procedures](../production-deployment/redis-and-recovery.md).
