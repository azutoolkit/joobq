---
title: Security, Audit & Payload Redaction
description: The console's trust boundaries, how sessions and tokens are checked, what the audit log records, and the layers that keep secrets out of views and archives.
order: 3
product: console
---

## Trust boundaries

Anyone who can write to Redis can change jobs, histories and console state; anyone who can read it or its backups can read unsealed payloads. Treat Redis access as administrator access: TLS (`rediss://`), an ACL user, a private network. The console adds a second boundary in front of the same data: every `/api/v1` route needs authentication (except a short public list) and a role.

## Who is calling

Three credentials are tried in order:

1. A bearer token whose SHA-256 is in `JOOBQUI_API_TOKENS`, compared in constant time. It belongs to no account.
2. A bearer token an admin created (`jq_…`). Only its hash is stored; it is looked up on every request, so a revocation works at once. Unknown well-formed tokens are cached briefly and floods of guesses are cut off.
3. The console's session cookie: encrypted and signed, valid for `JOOBQUI_SESSION_TTL_MINUTES` after sign-in. Sign-out, a password change or reset, a role change, deactivation or erasure revokes sessions on the server (in Redis), and the account's role and active flag are re-checked at most every 30 seconds, so a demotion holds even if a revocation could not be written.

Cookie requests that change state must send `X-Requested-With: joobqui`, which a cross-site form cannot set. Sign-in, sign-up, password recovery, second-factor guesses and SSO starts are rate limited with counts in Redis, shared by every instance.

## Second factor and single sign-on

TOTP secrets and notification-channel secrets are sealed with AES-256-GCM under a key derived from `JOOBQUI_SECRETS_KEY`; production refuses two-factor enrolment without it. Single sign-on is the OpenID Connect authorization-code flow with PKCE (S256), tied to the browser by a short-lived cookie. Roles from the provider's groups apply unless an admin locked the role by setting it by hand.

## The audit log

Every state-changing call, sign-in, sign-out and sign-up becomes a row: actor, role, client address, action (`token.create`, `user.role`, `mfa.reset`, `workflow.bulk_cancel`, …), target, outcome and request id. Bodies, passwords, tokens, codes and URLs never go in a row, and text from callers is cleaned of control characters and cut to length. Command-line tasks are recorded as `cli:<user>`.

Changes to who has access or what protects it (tokens, roles, activation, erasure, second factor, notification channels) are **critical**: a `pending` intent row is written first, and if that write fails the action is refused with `503`. An action that could not be recorded does not happen. The audit log is held in PostgreSQL, searchable and exportable by admins, and pruned after `JOOBQUI_AUDIT_RETENTION_DAYS`.

The log is an operational record in your database, not a tamper-proof ledger: someone with write access to PostgreSQL can change it. Protect it with database permissions and backups.

## Redaction, in layers

| Layer | What it does |
| --- | --- |
| `encrypted_property` (JoobQ core) | Chosen job fields are sealed at rest; only workers with the keys open them |
| Console masking | Values of secret-looking keys (`password`, `secret`, `token`, `api_key`, `authorization`, `cookie`, `credential`, `private_key`, …), at any depth, in every answer, stream event and export; `key=value` pairs and `user:password@host` inside error text too |
| Sealed values in the console | Shown as `[encrypted]`; the API holds no key and never decrypts |
| Error scrubbing (JoobQ core) | Plain values of sealed fields are scrubbed from recorded errors, causes and backtraces |
| Workflow archive | `event_redactor` / `state_redactor` (`Redaction.mask`, `Redaction.strip`) before a closed run is written; on by default in JoobQUI |
| Replay output | `ReplayResult#redacted` drops event data before you share a divergence |

Masking is by key name: a field called `author` is masked because it contains `auth`. Name fields for what they hold.

## What this is not

- Not a sandbox: anyone with Redis write access can enqueue or alter work.
- Not exactly-once: jobs and activities can repeat; make side effects idempotent.
- Exports are limited (10,000 entries) and CSV exports hold no payloads, but an export still holds data: handle it like the database it came from.
