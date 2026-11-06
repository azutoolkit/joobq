---
description: Bridge a database transaction and Redis admission without hiding the crash window.
---

# Enqueue from a transactional outbox

*How-to · Core*

## Prerequisites

- A SQL database for your application (the example is PostgreSQL) and a dispatcher process you write; JoobQ supplies no outbox dispatcher.

## Steps

1. Create an outbox table and insert the intent in the same transaction as the business change. `$1` and `$2` are bound parameters; the key is a versioned business key such as `order:42:receipt:v1`:

```sql
CREATE TABLE job_outbox (
  operation_key text PRIMARY KEY,
  payload jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  admitted_at timestamptz
);

BEGIN;
UPDATE orders SET state = 'placed' WHERE id = $1;
INSERT INTO job_outbox (operation_key, payload)
VALUES ($2, jsonb_build_object('order_id', $1))
ON CONFLICT (operation_key) DO NOTHING;
COMMIT;
```
2. In the dispatcher, claim a bounded set of rows that are not admitted, with row locking or a renewable lease, so two dispatchers do not take the same row.
3. Enqueue each job with the row's business key in its payload.
4. Mark the row admitted only after the enqueue returned; if it raised, leave the row for the next pass.
5. Reclaim rows whose claim was abandoned and dispatch them again with the same business key.
6. Make the job's handler [idempotent](write-idempotent-jobs.md): a crash between steps 3 and 4 enqueues the row again.

## Verify

- Stop the dispatcher between enqueue and marking: on restart the row is enqueued again and the effect still happens once.
- No row stays without `admitted_at` longer than your dispatch interval.

## See also

- [Reliability and recovery](../explanation/reliability-and-recovery.md): the two-commit gap the outbox closes.
