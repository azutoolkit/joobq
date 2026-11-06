---
description: Retries should repeat the attempt without repeating the business effect.
---

# Write idempotent jobs

*How-to · Core*

## Prerequisites

- The external effect the job performs (a charge, an email, a row) and a store that can enforce a unique key for it.

## Steps

1. Derive a key from the operation, for example `order:42:receipt:v1`, never a random value per attempt. Put it in the job's payload.
2. For a database effect, write the result and the key in one transaction, with a unique constraint on the key.
3. For an HTTP effect, send the key to the provider's idempotency API and store the result it returns.
4. If the provider has no idempotency API, record the attempt before the call and reconcile unclear outcomes from the provider's records.
5. Keep the same key when you redrive or re-enqueue the work. Use the same rule in workflow activities (`context.dedupe_key` is stable only within one run) and in compensations.

## Verify

- Run the job twice with the same payload (enqueue it twice, or redrive it after it succeeds): the effect happens once.
- In a test, make the job raise after the effect and before it returns: the retry does not repeat the effect.

## See also

- [Reliability and recovery](../explanation/reliability-and-recovery.md): why work runs twice, and which identities JoobQ provides.
