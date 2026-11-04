---
title: Deploy Licensed Self-Hosted
description: Build the joobqui-selfhosted image, give it a license key, PostgreSQL and Redis, run the web and worker processes, and check its health.
order: 6
product: console
---

`joobqui-selfhosted` is one binary that serves the console (`/ui/`), the JSON and WebSocket API (`/api/v1`) and Prometheus metrics (`/metrics`), runs the queue worker (`--worker`), and carries the command-line tasks. It needs:

- **PostgreSQL** for accounts, API token hashes, the audit log, notification channels and migrations;
- the **Redis** your JoobQ workers use (single server, version 5+);
- a **license key** (`jq_lic_…`) from the license portal.

## 1. Build the image

`Dockerfile.selfhosted` builds the console and a static binary. JoobQ Pro is a private shard, so pass a token that can read it as a BuildKit secret; it never lands in an image layer.

```bash
docker build -f Dockerfile.selfhosted \
  --secret id=github_token,env=GITHUB_TOKEN \
  -t joobqui-selfhosted .
```

The image runs as user `10001`, sets `CRYSTAL_ENV=production` and exposes port `4000`. You may bake a license into it with `--secret id=joobqui_license,src=license.key` (it is written to `/app/config/license.key`).

## 2. Provide the license

The key is read in this order: a renewed key the console stored in Redis, then `JOOBQUI_LICENSE` or `JOOBQUI_LICENSE_FILE` (set one, not both), then the baked `/app/config/license.key` (or `JOOBQUI_LICENSE_PATH`). Prefer a file mounted from your secret manager:

```bash
-e JOOBQUI_LICENSE_FILE=/run/secrets/joobqui_license
```

`DATABASE_URL`, `SESSION_SECRET` and `REDIS_URL` also accept the `*_FILE` form.

## 3. Run the web and worker processes

```yaml
# compose.yaml (excerpt)
services:
  web:
    image: joobqui-selfhosted
    ports: ["4000:4000"]
    environment:
      DATABASE_URL_FILE: /run/secrets/database_url
      SESSION_SECRET_FILE: /run/secrets/session_secret
      REDIS_URL: rediss://default@redis.internal:6380/0
      JOOBQUI_SECRETS_KEY: ${JOOBQUI_SECRETS_KEY}          # no *_FILE form
      JOOBQUI_LICENSE_FILE: /run/secrets/joobqui_license
      JOOBQUI_PUBLIC_URL: https://joobqui.acme.io
      JOOBQUI_CLIENT_IP_HEADER: X-Real-IP
    secrets: [database_url, session_secret, joobqui_license]
  worker:
    image: joobqui-selfhosted
    command: ["./joobqui-selfhosted", "--worker"]
    environment:
      DATABASE_URL_FILE: /run/secrets/database_url
      SESSION_SECRET_FILE: /run/secrets/session_secret
      REDIS_URL: rediss://default@redis.internal:6380/0
      JOOBQUI_LICENSE_FILE: /run/secrets/joobqui_license
    secrets: [database_url, session_secret, joobqui_license]
```

`JOOBQUI_SECRETS_KEY` has no `*_FILE` form: pass it from your secret store as a variable. In production `SESSION_SECRET` must be at least 32 characters, and two-factor enrolment needs `JOOBQUI_SECRETS_KEY`.

The worker serves no HTTP: give it a process-level health check. It runs JoobQ's queues and the YAML `schedulers:`. Workflow schedules fire in a JoobQ Pro worker, or in the web process with `JOOBQUI_WORKFLOW_SCHEDULER=true`.

Migrations run at start; `./joobqui-selfhosted migrate` runs them on their own. Start-up retries PostgreSQL and Redis for `JOOBQUI_BOOT_WAIT_SECONDS` (60) and then exits with one line naming what failed.

## 4. Create the first admin and check health

```bash
docker compose exec web ./joobqui-selfhosted accounts:create ada@acme.io ada
docker compose exec web ./joobqui-selfhosted doctor
# {"status":"ok","database":true,"redis":true,"session":true,"license":true}
docker compose exec web ./joobqui-selfhosted license:status
```

`doctor` exits `1` when any check fails. Put the console behind TLS at `JOOBQUI_PUBLIC_URL` and open `/ui/`.

## How the license is checked

- The web process checks in with the license service every 15 minutes, sending its origin, the number of active accounts and its version; a renewed key is stored in Redis (`joobqui:license:active_token:<deployment id>`). `license:refresh` checks in at once.
- If the service cannot be reached, the last good license holds for **24 hours** after the last successful check-in, as long as its paid-until date is in the future.
- When the license is expired, unpaid or disabled, `/api/v1` and `/metrics` answer `402 paid_license_required`. Sign-in and account routes keep working, and queue workers keep processing jobs.
- Tiers set limits: Starter 5 seats and 1 deployment, Team 25 seats and 3 deployments with single sign-on, Enterprise unlimited seats and 10 deployments.

## Several web instances

Run as many web instances as you like behind a load balancer. Sessions, revocations and rate limits live in Redis; alert notifications and audit retention are done by the instance holding a Redis lease (`joobqui_leader{role}` on `/metrics`). Set `JOOBQUI_CLIENT_IP_HEADER` to the header your proxy sets.
