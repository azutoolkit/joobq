---
title: Console RBAC Matrix
description: What viewer, operator and admin may do in JoobQUI, which routes need no sign-in, and how credentials map to roles.
order: 4
product: console
---

Roles are ordered: `viewer` < `operator` < `admin`, each including the ones before. A route that names no role needs `viewer` for a `GET` and `operator` for anything that changes state, so a new write route is operator-only until it says otherwise. Too low a role is `403 forbidden_role` whatever the credential. Each route's role is in `GET /api/v1/openapi.json` as `x-required-role`.

## Matrix

| Area | viewer | operator | admin |
| --- | :---: | :---: | :---: |
| Overview, telemetry, live stream | ✓ | ✓ | ✓ |
| Queues: view, export | ✓ | ✓ | ✓ |
| Queues: pause, resume, clear, change concurrency | | ✓ | ✓ |
| Jobs and payloads (secret-looking values masked) | ✓ | ✓ | ✓ |
| Jobs: retry, run now, delete | | ✓ | ✓ |
| Dead letters: view, export | ✓ | ✓ | ✓ |
| Dead letters: redrive, purge | | ✓ | ✓ |
| Workers | ✓ | ✓ | ✓ |
| Workflows: list, detail, history, query | ✓ | ✓ | ✓ |
| Workflows: start, signal, cancel, terminate, retry step, re-drive, bulk | | ✓ | ✓ |
| Workflows: set search attributes, updates, replay, migrate, continue-as-new, cancel a scope | | ✓ | ✓ |
| Workflows: migrate with `force` | | | ✓ |
| Workflow archive: view | ✓ | ✓ | ✓ |
| Workflow archive: replay | | ✓ | ✓ |
| Worker builds: view | ✓ | ✓ | ✓ |
| Worker builds: promote, retire, re-pin | | | ✓ |
| Search attribute names: register | | | ✓ |
| Schedules: pause, resume, run now | | ✓ | ✓ |
| Workflow schedules: pause, resume, trigger, backfill | | ✓ | ✓ |
| Workflow schedules: create, change, delete | | | ✓ |
| Alerts: view | ✓ | ✓ | ✓ |
| Alert rules: create, enable, disable, delete; acknowledge | | ✓ | ✓ |
| Notification channels (reads included) | | | ✓ |
| Users: list, re-role, activate, erase, export, reset 2FA | | | ✓ |
| API tokens: create, revoke | | | ✓ |
| Audit log: view, export | | | ✓ |
| Own two-factor authentication | ✓ | ✓ | ✓ |
| `/metrics` | ✓ | ✓ | ✓ |

Managing users, tokens and notification channels also needs a **console session**: a stored API token, even an admin's, is refused with `403 session_required`.

## No sign-in needed

`GET /capabilities`, `GET /openapi.json`, `POST /session`, `POST /session/mfa`, `POST /accounts` (governed by `JOOBQUI_SIGNUP`), `POST /password/forgot`, `POST /password/reset`, `POST /email/verify`, `POST /email/resend`, and with SSO configured `GET /auth/oidc/start` and `GET /auth/oidc/callback`. Every other path, existing or not, answers `401` to a stranger before any routing.

## Where roles come from

| Credential | Role |
| --- | --- |
| Account (password or SSO) | The account's role. Command line: first account admin, later operator unless `--role`. Sign-up: viewer, or the invite's role. SSO: from `JOOBQUI_OIDC_ROLE_MAP` |
| Stored API token (`jq_…`) | Chosen by the admin who created it; treated as no token while its owner must enrol 2FA |
| Environment token (`JOOBQUI_API_TOKENS`) | `hash:role`; no role means operator. Cannot manage users or tokens unless `JOOBQUI_ALLOW_ENV_TOKEN_ADMIN=true` |

A role change, deactivation or erasure ends the account's sessions at once (revocations live in Redis), and the role in each session is re-checked against the database at most every 30 seconds.
