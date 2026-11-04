---
title: Triage & Redrive Dead Letters
description: Find out why jobs died, fix the cause, and send them back to their queues from the console, the API or Crystal.
order: 1
product: console
---

A job is dead-lettered when its retries are exhausted, or at once when its sealed fields cannot be opened (`decryption_error`). Dead letters live in one Redis sorted set (`joobq:dead_letter`), newest first. Nothing prunes them by age: plan an export and purge policy.

## 1. Look before you act

In JoobQUI open **Dead letters**. Filter by queue and open an entry: you see the job class, queue, failure time, error message and retry count, and the payload with secret-looking keys shown as `[redacted]` and sealed fields as `[encrypted]`.

Group what you see by error:

| Error | Usually means | Before redriving |
| --- | --- | --- |
| A timeout or connection error from a dependency | The dependency was down | Check it is back |
| An exception in your code | A bug or bad data | Deploy the fix, keep the class compatible with the old payload |
| `decryption_error` | The worker had no key for the sealed value, or the value was altered | Restore the key (`JOOBQ_PAYLOAD_KEYS`) |

Export what you are about to change: **Export** (CSV or JSON, at most 10,000 entries; the CSV holds no payloads) or `GET /api/v1/export/dlq?format=json&queue=emails`.

## 2. Redrive

Select the entries and choose **Redrive** (operator role). Each job goes back to the end of its queue with a fresh retry budget. The answer reports every job:

```json
{ "succeeded": 3, "missing": [], "unredrivable": ["3b7d…0c19"], "conflicted": [] }
```

- `missing`: someone else already redrove or purged it.
- `unredrivable`: the stored entry cannot be rebuilt into a job (malformed or withheld payload, or its queue no longer exists). Do not hand-edit Redis to force it.
- `conflicted`: it changed between lookup and redrive; look again.

Two operators racing see each job succeed once. A redrive is not exactly-once for side effects: a job that died after its external call can repeat that call, so jobs must be idempotent.

## 3. Purge what you will not replay

**Purge** removes selected entries; `POST /api/v1/dlq/purge {"queue": "emails", "all": true}` clears a queue's dead letters. Both are audited (`dlq.purge`).

## From the API

```bash
curl -s -H "Authorization: Bearer $TOKEN" "https://joobqui.internal/api/v1/dlq?queue=emails&limit=50"
curl -s -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"jids": ["9f2c…a41e", "c81a…77f2"]}' https://joobqui.internal/api/v1/dlq/redrive
```

A bearer token needs the operator role for redrive and purge. Lists page with `cursor`/`next_cursor`, `limit` at most 200.

## From Crystal (JoobQ core)

```crystal
dlq = JoobQ::DeadLetterQueue.new
dlq.page(0, 20, queue: "emails").each { |entry| puts "#{entry.jid} #{entry.error}" }
outcome = dlq.redrive(["9f2c…a41e"])
outcome.succeeded  # also #missing, #unredrivable, #conflicted
```

`redrive_reviewed(jid, expected_digest)` replays only the exact member you reviewed (SHA-256 of the stored entry), and `purge(jids)` / `purge_all(queue)` remove entries.

## Failed workflows are different

A failed workflow run is not a dead letter. Retry one step (`POST /api/v1/workflows/:id/steps/:step/retry`) or re-drive the run, which starts a new run `<id>-redrive` with the same input. See [Operate workflows in production](/docs/how-to/operate-workflows-in-production).
