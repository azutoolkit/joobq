---
description: Which feature is in the open-source core, in the Pro shard and in the JoobQUI console, row by row.
---

# Open Source vs Pro vs JoobQUI feature matrix

*Reference · Core · Pro · JoobQUI*

"Pro" includes everything in Core. "JoobQUI" is what the console and its API add to whatever your workers run. **Preview** is shipped but still settling; **Roadmap** is not shipped.

## Jobs and queues

| Feature | Core | Pro | JoobQUI |
| --- | --- | --- | --- |
| Typed jobs, Redis queues, per-queue worker counts | yes | yes | pause, resume, clear, set concurrency |
| Retries with exponential backoff, `NonRetryableError` | yes | yes | |
| Dead letters and redrive | yes | yes | list, redrive, purge, export (CSV, JSON) |
| Delayed jobs (`delay`, `enqueue_at`) | yes | yes | |
| Interval and cron loops in one process | yes | yes | |
| YAML `schedulers:` that fire | no (loaded, never fired) | no | yes, for job classes built into JoobQUI |
| Per-queue throttle, in one process | yes | yes | |
| Job expiry (`expires`) | yes | yes | |
| Cross-process rate limit (`RateLimiter`) | | yes | |
| Durable batches, unique admission | | Preview | |
| Delivery runtime (leases, receipts) | Preview | Preview | |
| Sealed fields (`encrypted_property`, AES-256-GCM) | yes | yes | shown as `[encrypted]`; the SDK gateway seals for SDK workers |
| Priority field | no (separate queues) | no | |
| Idempotency key | `jid` only | unique admission | |

## Workflows

| Feature | Core | Pro | JoobQUI |
| --- | --- | --- | --- |
| Workflows with steps, `parallel`, `after:` | | yes | runs, history, graph |
| Signals, queries, updates, timers, child workflows | | yes | signal, query, send updates |
| Sagas (compensation newest first), cancel and terminate | | yes | cancel, terminate, retry a step |
| Cancellation scopes, continue-as-new | | yes | cancel one scope |
| Workflow schedules (overlap, catch-up, time zone) | | yes | create, trigger, backfill |
| Worker build ids | | yes | promote, retire, re-pin |
| Typed workflow DSL | | Preview | |
| Dynamic fan-out (`for_each`) | | Roadmap | |
| Workflow and activity rate limits | | Roadmap | |
| Multi-tenancy (namespaces) | | Roadmap | |

## Operations and security

| Feature | Core | Pro | JoobQUI |
| --- | --- | --- | --- |
| HTTP management API | `/joobq/*`, bearer tokens, off by default | adds `/joobq/metrics`, `/joobq/percentiles`, `/joobq/alerts` | `/api/v1`, described at `/api/v1/openapi.json` |
| Run-time histogram | in Redis (`joobq:stats:latency`) | percentiles in process | charts; `joobqui_job_duration_seconds` |
| Prometheus endpoint | no | no (Roadmap) | `/metrics` |
| Alert rules | | yes (log handler; webhook handler only logs) | rules, acknowledgement |
| Alert channels: email, Slack, PagerDuty, webhook | | | yes (webhook HMAC-signed when it has a secret) |
| Roles, API tokens, audit log | three API token roles | | viewer, operator, admin; audit log |
| TOTP two-factor, OIDC single sign-on | | | yes |
| Masking of secret-looking payload keys | | | wherever JoobQUI shows a payload |
| Workers in other languages | | | Python, TypeScript, Ruby, Go, Rust, Java, PHP, .NET through `/api/v1/sdk` |

## See also

- [Open Source vs Pro vs JoobQUI](../explanation/pro-features.md): how the three layers fit.
- [Compatibility](compatibility.md)
