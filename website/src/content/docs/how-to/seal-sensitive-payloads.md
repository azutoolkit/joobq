---
title: Seal Sensitive Payloads
description: Encrypt chosen job fields at rest with encrypted_property, rotate keys, and keep secrets out of the console, logs and workflow archives.
order: 4
product: oss
---

A job is stored as JSON in Redis: in its queue, the processing list, the retry and scheduled sets and the dead letters, and in every backup of them. Seal the fields that must not be readable there.

## 1. Mark the fields

```crystal
class ChargeJob
  include JoobQ::Job

  @queue = "billing"
  property order_id : Int64 = 0                        # stays readable
  encrypted_property card_token : String = ""
  encrypted_property billing : Hash(String, String)? = nil

  def perform
    charge(card_token)   # plain text here
  end
end
```

Sealed fields are written as AES-256-GCM values (`jqe1:...`) and opened when the worker loads the job, before `perform`. Each value carries its key id, a random 96-bit nonce and the tag; the job class and field name are authenticated, so a value copied to another field or class is refused. Renaming the class or field makes stored values unreadable: pin the name with `job_name:` on `encrypted_property`.

## 2. Give every process the keys

A key is `id:key`: 32 bytes as 64 hex digits or base64, and an id of 1 to 16 of `a-z 0-9 _ -`. The first key seals; the others only open.

```bash
export JOOBQ_PAYLOAD_KEYS="2026b:$(openssl rand -hex 32),2026a:<old key>"
```

Or in code:

```crystal
JoobQ.configure do
  payload_encryption current: "2026b:#{ENV["NEW_KEY"]}", previous: ["2026a:#{ENV["OLD_KEY"]}"]
end
```

Every process that enqueues or runs such a job needs the keys. Without them the queue of a job class with sealed fields refuses to start and enqueueing raises `JoobQ::Encryption::Error`. In the JoobQUI processes the same keys are read from `JOOBQUI_PAYLOAD_KEYS`; the web process never needs them, because the console shows sealed values as `[encrypted]` and never decrypts.

## 3. Rotate

1. Put the new key first and keep the old one after it. Deploy everywhere.
2. Wait until no job sealed with the old key can still be in Redis (dead letters included). A retried job is rewritten with the current key.
3. Remove the old key.

Rotate before about 2^32 seals per key (random nonces).

## 4. When a value cannot be opened

- The **job's** fault (unknown key id, wrong class or field, altered or damaged value): the job is never run; it is dead-lettered with error type `decryption_error` and a message that names the class and field but no value. Restore the key and redrive it.
- The **process's** fault (no keys, malformed `JOOBQ_PAYLOAD_KEYS`): the worker puts the job back on its queue and backs off instead of dead-lettering it.

Values written before a field was sealed are read as they are and sealed on the next write. Set `JoobQ.config.allow_plaintext_payloads = false` to refuse them once old jobs have drained (`JOOBQUI_ALLOW_PLAINTEXT_PAYLOADS` in JoobQUI workers).

## What sealing does not cover

- In memory and in your own logs the values are plain. JoobQ scrubs them from the errors it records; it cannot scrub what `perform` logs.
- The size of a value is not hidden, and a sealed value can be copied between jobs of the same class and field by someone who can write to Redis.

## Masking everywhere else

- **Console and API.** Values of keys that look secret (`password`, `secret`, `token`, `api_key`, `authorization`, `cookie`, `credential`, `private_key`, ...) are shown as `[redacted]` in every view, the live stream and exports, at any depth.
- **Workflow archives.** Pass an `event_redactor` such as `JoobQPro::Workflows::Redaction.mask(%w[password card_number])` to `FileArchive`; the archive is then marked redacted and cannot be replayed. In JoobQUI, `JOOBQUI_WORKFLOW_ARCHIVE_REDACT` is on by default.
- **Search attributes** are stored unmasked in workflow history: never put a secret in one.
