---
title: REST API, Webhooks & Prometheus Metrics
description: JoobQ's management API, the JoobQUI /api/v1 routes and error format, signed alert webhooks, and the metrics on /metrics.
order: 3
---

## JoobQ management API

`APIServer` (started by `JoobQ.forge` when `rest_api_enabled`) listens on port 8080, on loopback unless you change it, and needs a bearer token from `JOOBQ_API_READER_TOKEN`, `JOOBQ_API_OPERATOR_TOKEN` or `JOOBQ_API_ADMIN_TOKEN`. The OpenAPI 3.0 description is `docs/openapi.yaml` in the repository.

| Route | Purpose |
| --- | --- |
| `GET /joobq/health/check` | Health |
| `GET /joobq/jobs/registry` | Registered job classes and their JSON schemas |
| `POST /joobq/jobs` | Enqueue a job |
| `GET /joobq/jobs/retrying`, `GET /joobq/jobs/dead` | Retrying and dead jobs |
| `POST /joobq/jobs/:job_id/retry` | Retry one job |
| `POST /joobq/queues/:queue_name/reprocess` | Move a queue's busy jobs back |
| `GET /joobq/errors/stats`, `/recent`, `/by-type`, `/by-queue` | Error monitoring |
| `GET /joobq/pipeline/health`, `/stats` | Redis pipeline health |

JoobQUI does not serve these: under `/joobq` it answers `404` except `GET`/`HEAD /joobq/health/check`.

## JoobQUI `/api/v1`

Same origin as the console. Authenticate with the session cookie or `Authorization: Bearer <token>`. Requests made with the cookie that change state must send `X-Requested-With: joobqui`. A request with a body must be `Content-Type: application/json`. `GET /api/v1/openapi.json` (public) is the OpenAPI 3.1 description, with each route's role in `x-required-role`.

**Errors** are `{"error": {"code", "message", "details", "request_id"}}`, and `X-Request-Id` is echoed on every response. Common codes: `401 unauthenticated`, `401 mfa_required`, `403 forbidden_role`, `403 mfa_enrolment_required`, `404 not_found`, `409 conflict`, `413 payload_too_large` (256 KiB), `422 invalid_request`, `429 rate_limited` (with `Retry-After`), `402 paid_license_required`, `503 unavailable`.

**Lists** are `{"items": [...], "next_cursor": string|null}`; send `next_cursor` back unchanged as `cursor`; `limit` at most 200.

| Area | Routes |
| --- | --- |
| Session | `GET/POST/DELETE /session`, `POST /session/mfa`, `GET /capabilities` |
| Queues | `GET /queues`, `POST /queues/:n/pause\|resume\|clear`, `PUT /queues/:n/concurrency` |
| Jobs | `GET /jobs?state=waiting\|delayed\|retrying\|processing`, `GET /jobs/:jid`, `POST /jobs/retry`, `POST /jobs/delete` |
| Dead letters | `GET /dlq`, `POST /dlq/redrive {jids}`, `POST /dlq/purge` |
| Workflows | `GET/POST /workflows`, `GET /workflows/:id`, `…/history`, `…/signal`, `…/query`, `…/cancel`, `…/terminate`, `…/steps/:step/retry`, `…/redrive`, `POST /workflows/bulk` |
| Workflow lifecycle | `…/replay`, `…/migrate`, `…/continue-as-new`, `…/updates/:name`, `…/scopes/:scope/cancel`, `/workflow-schedules`, `/workflow-builds`, `/workflow-attributes`, `/workflow-archive` |
| Schedules | `GET /schedules`, `POST /schedules/:id/pause\|resume\|run` |
| Telemetry | `GET /telemetry/summary?window=1m\|15m\|1h\|24h\|7d&queue=` |
| Alerts | `GET /alerts`, `/alerts/rules`, `POST /alerts/:id/acknowledge`, `/notification-channels` |
| Access | `GET/PUT /users…`, `GET/POST/DELETE /tokens`, `GET /audit`, `/mfa…`, `/auth/oidc/start\|callback` |
| Exports | `GET /export/queues`, `GET /export/dlq?format=csv\|json` |
| Live stream | `GET /stream` (WebSocket, `?since=<id>`), envelope `{v: 1, id, ts, type, data}` |

## Alert webhooks

A webhook channel receives JSON for each alert event:

```json
{ "event": "fired", "sent_at": 1762300000000, "alert": { "rule_id": "…", "rule_name": "Dead letters accumulating", "metric": "dead", "current_value": 4.0, "threshold": 1.0, "severity": "warning", … } }
```

`event` is `fired`, `resolved` or `test`. Headers:

- `X-JoobQUI-Delivery: <event>:<alert id>`: use it to drop repeats (deliveries are retried).
- With a secret set: `X-JoobQUI-Timestamp` (Unix seconds) and `X-JoobQUI-Signature: sha256=<hex HMAC-SHA256 of "<timestamp>.<raw body>">`.

Verify on the receiver:

```crystal
expected = "sha256=" + OpenSSL::HMAC.hexdigest(:sha256, secret, "#{timestamp}.#{raw_body}")
ok = Crypto::Subtle.constant_time_compare(expected, signature) &&
     (Time.utc.to_unix - timestamp.to_i64).abs <= 300
```

Slack channels take an incoming-webhook URL; PagerDuty channels use the Events API v2 with the alert's rule as `dedup_key`, so a resolve closes its trigger. URLs must be `https` and may not resolve to private, loopback or link-local addresses.

## Prometheus `/metrics`

Text format 0.0.4, viewer role (a bearer token works). Families:

| Metric | Type | Labels |
| --- | --- | --- |
| `joobqui_queue_size`, `_processing`, `_dead`, `_paused`, `_concurrency` | gauge | `queue` |
| `joobqui_jobs_processed_total` | counter | `queue` |
| `joobqui_job_duration_seconds` | histogram | `queue` |
| `joobqui_workers_registered` | gauge | |
| `joobqui_workflows` | gauge | `status` |
| `joobqui_workflow_pruned_total`, `_archived_total` | counter | |
| `joobqui_workflow_archive_failures` | gauge | |
| `joobqui_leader` | gauge | `role` (`alerts`, `retention`) |
| `joobqui_api_requests_total` | counter | method, route, status class |
| `joobqui_api_request_duration_seconds` | histogram | method, route, status class |
| `joobqui_build_info`, `joobqui_process_start_time_seconds` | gauge | versions |
| `joobqui_metrics_truncated` | gauge | 1 when some queues were left out |

```yaml
scrape_configs:
  - job_name: joobqui
    scheme: https
    metrics_path: /metrics
    authorization: { credentials_file: /etc/prometheus/joobqui-token }
    static_configs: [{ targets: ["joobqui.acme.io"] }]
```
