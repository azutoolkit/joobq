---
title: Configuration & Env Vars
description: JoobQ's configuration properties and environment variables, and the variables the JoobQUI console reads.
order: 2
---

## JoobQ core: `JoobQ.configure`

| Property | Default | Meaning |
| --- | --- | --- |
| `default_queue` | `"default"` | Queue a job uses when it sets no `@queue` |
| `retries` | `3` | Retries after the first attempt |
| `expires` | `3.days` | A job not run by then is marked expired |
| `timeout` | `2.seconds` | Longest a job may run |
| `dead_letter_ttl` | `7.days` | Recorded, but the Redis store does not prune dead letters by age |
| `rest_api_enabled` | | Start the management REST API with `forge` |
| `allow_plaintext_payloads` | `true` | Accept unsealed values for `encrypted_property` fields |
| `store` | `RedisStore` | Where jobs are kept |

Inside the block: `queue name, workers, JobClass, throttle: {limit:, period:}`, `scheduler(tz) { cron(...) {…}; every span, Job, **args }` and `payload_encryption current:, previous:`. A YAML file (`config/joobq.<env>.yml`, or `JOOBQ_CONFIG_PATH`) can declare `settings`, `queues`, `middlewares`, `schedulers` and `redis` instead.

### Environment variables

| Variable | Default | Meaning |
| --- | --- | --- |
| `REDIS_URL` | | `redis://[user:password@]host[:port][/db]`, `rediss://` (TLS) or `unix:///path.sock[?db=N]`; wins over the three below |
| `REDIS_HOST`, `REDIS_PORT`, `REDIS_PASS` | `localhost`, `6379`, none | Plain connection |
| `REDIS_TLS_VERIFY`, `REDIS_CA_FILE` | `true`, system CAs | Certificate and host-name checks; extra CA to trust |
| `REDIS_POOL_SIZE`, `REDIS_POOL_TIMEOUT` | `500`, `2.0` | Connection pool |
| `REDIS_TIMEOUT` | | Per-operation timeout, seconds |
| `JOOBQ_ENV` | `development` | Selects the YAML file |
| `JOOBQ_CONFIG_PATH` | auto | Another YAML file |
| `JOOBQ_PAYLOAD_KEYS` / `JOOBQ_PAYLOAD_KEY` | | `id:key,...` for `encrypted_property`; first seals |
| `JOOBQ_EVENTS_MAX_BYTES` | 64 MiB | Memory cap for the `joobq:events` stream (0 = off) |
| `JOOBQ_TRAP_SIGNALS` | on | `0` makes `forge` leave signal handlers to you |
| `JOOBQ_API_READER_TOKEN`, `_OPERATOR_TOKEN`, `_ADMIN_TOKEN` | | Bearer tokens for the management API (32+ bytes) |

## JoobQ Pro

| Variable | Meaning |
| --- | --- |
| `JOOBQ_PRO_LICENSE` | The Pro license key |
| `JOOBQ_PRO_BUILD_ID` | Default `build_id:` of a workflow `Worker` |

## JoobQUI

### Required

| Variable | Meaning |
| --- | --- |
| `DATABASE_URL` | PostgreSQL; the database must exist, migrations run at start |
| `SESSION_SECRET` | Session signing secret (`openssl rand -hex 32`); 32+ characters in production |
| `JOOBQUI_LICENSE` or `JOOBQUI_LICENSE_FILE` | The `jq_lic_…` key (or a baked `/app/config/license.key`) |

`DATABASE_URL`, `SESSION_SECRET`, `REDIS_URL` and `JOOBQUI_LICENSE` also accept a `*_FILE` variant pointing at a secret file.

### Server and storage

| Variable | Default | Meaning |
| --- | --- | --- |
| `HOST`, `PORT` | `0.0.0.0`, `4000` | Listen address |
| `CRYSTAL_ENV` | `development` | `production` turns on HSTS and the production start-up checks |
| `REDIS_URL`, `REDIS_USER`, `REDIS_TLS`, `REDIS_TLS_VERIFY`, `REDIS_CA_FILE` | | Redis connection (no Sentinel or Cluster) |
| `JOOBQUI_DB_POOL_SIZE`, `JOOBQUI_DB_IDLE_POOL_SIZE`, `JOOBQUI_DB_CHECKOUT_TIMEOUT` | `20`, `min(pool, 10)`, `5.0` | PostgreSQL pool |
| `JOOBQUI_BOOT_WAIT_SECONDS` | `60` | How long start-up waits for PostgreSQL and Redis |
| `JOOBQUI_UI_DIR` | `public/ui` | Built console files |
| `JOOBQUI_PUBLIC_URL` | | Base of mailed links and the SSO redirect URI |
| `JOOBQUI_CLIENT_IP_HEADER` | | Header a trusted proxy sets to the caller's address |

### Accounts and security

| Variable | Default | Meaning |
| --- | --- | --- |
| `JOOBQUI_SIGNUP` | `closed` | `open`, `invite` or `closed` |
| `JOOBQUI_ACCOUNT_PASSWORD` | | Password for `accounts:create` |
| `JOOBQUI_SESSION_TTL_MINUTES` | `60` | Session lifetime, 5 to 1440 |
| `JOOBQUI_REQUIRE_EMAIL_VERIFICATION` | `false` | Open sign-ups stay inactive until confirmed |
| `JOOBQUI_API_TOKENS` | | Comma-separated SHA-256 hashes, each optionally `:viewer`, `:operator` or `:admin` |
| `JOOBQUI_ALLOW_ENV_TOKEN_ADMIN` | `false` | Let an admin environment token manage users and tokens |
| `JOOBQUI_SECRETS_KEY` | `SESSION_SECRET` | Seals channel and second-factor secrets; required in production for 2FA |
| `JOOBQUI_MFA_REQUIRED_ROLES`, `JOOBQUI_MFA_SSO_EXEMPT` | | Roles that must enrol TOTP; exempt SSO sessions |
| `JOOBQUI_OIDC_ISSUER`, `_CLIENT_ID`, `_CLIENT_SECRET` | | Turn on single sign-on |
| `JOOBQUI_OIDC_NAME`, `_SCOPES`, `_GROUPS_CLAIM`, `_ROLE_MAP`, `_ALLOWED_DOMAINS` | `Single sign-on`, `openid email profile`, `groups` | Label, scopes, groups claim, `group=role,*=role`, domains |
| `JOOBQUI_OIDC_AUTO_CREATE`, `_LINK_BY_EMAIL`, `_ONLY`, `_ALLOW_PRIVATE_HOSTS` | `true`, `false`, `false`, `false` | Account creation and linking rules |
| `JOOBQUI_PAYLOAD_KEYS` | | Keys for sealed job fields, for worker processes |
| `JOOBQUI_ALLOW_PLAINTEXT_PAYLOADS` | `false` | Whether workers run unsealed values of sealed fields |

### Mail, alerts and retention

| Variable | Default | Meaning |
| --- | --- | --- |
| `SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `SMTP_FROM`, `SMTP_FROM_NAME` | port `587` | Mail (STARTTLS) |
| `JOOBQUI_ALERT_NOTIFICATIONS` | `on` | `off` stops this instance sending alerts |
| `JOOBQUI_ALLOW_PRIVATE_WEBHOOKS` | `false` | Allow http and internal webhook URLs (development) |
| `JOOBQUI_AUDIT_RETENTION_DAYS` | `365` | Audit events kept |
| `JOOBQUI_DLQ_RETENTION_DAYS`, `JOOBQUI_WORKFLOW_RETENTION_DAYS` | kept for ever | Expiry of dead letters and finished workflows |
| `JOOBQUI_RETENTION_BATCH`, `JOOBQUI_RETENTION_INTERVAL_MINUTES` | `500`, `60` | Retention pacing |
| `JOOBQUI_WORKFLOW_ARCHIVE_DIR` | | Archive finished runs before deletion |
| `JOOBQUI_WORKFLOW_ARCHIVE_MAX_RUNS`, `_MAX_BYTES`, `_REDACT` | `50000`, 16 MiB, `true` | Archive limits and redaction |
| `JOOBQUI_WORKFLOW_SCHEDULER` | `false` | Fire workflow schedules in the web process |
| `JOOBQUI_WORKFLOW_ATTRIBUTES` | | `name:type,...` search attributes registered at start |
| `LOG_LEVEL` | `INFO` | Logging level |
