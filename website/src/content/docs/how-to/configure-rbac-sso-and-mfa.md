---
title: Configure RBAC, SSO & MFA
description: Create the first admin, hand out roles and API tokens, require two-factor authentication, and sign in through your OpenID Connect provider.
order: 5
product: console
---

JoobQUI has three roles, each including the ones before it: **viewer** reads, **operator** also changes queues, jobs, dead letters, workflows, schedules and alert rules, **admin** also manages accounts, API tokens, notification channels and worker builds and reads the audit log. The server enforces the role on every route (`403 forbidden_role`). The full matrix is in the [RBAC reference](/docs/reference/console-rbac-matrix).

## 1. Create accounts

Sign-up in the console is closed by default. Make the first account on the command line; it becomes an admin:

```bash
JOOBQUI_ACCOUNT_PASSWORD='…' ./joobqui-selfhosted accounts:create ada@acme.io ada
./joobqui-selfhosted accounts:create lin@acme.io lin --role operator
./joobqui-selfhosted accounts:role lin@acme.io admin      # ends that account's sessions
./joobqui-selfhosted invites:create 7 --role viewer       # one-use sign-up code, valid 7 days
```

Without `JOOBQUI_ACCOUNT_PASSWORD` the password is asked for twice. Passwords need 8+ characters (at most 72 bytes) with upper and lower case, a digit and a special character. `JOOBQUI_SIGNUP` is `closed` (default), `invite` or `open` (new accounts are viewers).

Admins change roles and deactivate accounts on the **Access** page. The last active admin cannot be demoted or erased.

## 2. Issue API tokens for scripts

On the **Access** page an admin creates a token with a role and an optional expiry. It is shown once (`jq_…`); only its SHA-256 hash is stored, and revoking it takes effect at once. Use it as `Authorization: Bearer <token>`.

Managing tokens, users and notification channels needs a console session: a stored token, even an admin's, gets `403 session_required`. Tokens from `JOOBQUI_API_TOKENS` (SHA-256 hashes, optionally `hash:role`) belong to no account and cannot administer users or tokens unless `JOOBQUI_ALLOW_ENV_TOKEN_ADMIN=true`.

## 3. Turn on two-factor authentication

Any account can enable TOTP on its **Security** page: scan the QR code, confirm a code, and store the ten recovery codes, which are shown once. To require it for some roles:

```bash
JOOBQUI_MFA_REQUIRED_ROLES=admin,operator
JOOBQUI_SECRETS_KEY=$(openssl rand -hex 32)   # required in production; seals the TOTP secrets
```

Accounts with those roles must enrol at their next sign-in; until they do, every route but enrolment answers `403 mfa_enrolment_required`. Their API tokens count as no token until then. A lost phone: an admin uses **Reset 2FA**, or run `./joobqui-selfhosted accounts:mfa:reset EMAIL`, which also ends the account's sessions and revokes its tokens.

> Changing `JOOBQUI_SECRETS_KEY` makes stored second-factor and channel secrets unreadable. Keep it in your secret manager.

## 4. Single sign-on with OpenID Connect

```bash
JOOBQUI_PUBLIC_URL=https://joobqui.acme.io
JOOBQUI_OIDC_ISSUER=https://login.acme.io
JOOBQUI_OIDC_CLIENT_ID=joobqui
JOOBQUI_OIDC_CLIENT_SECRET=…
JOOBQUI_OIDC_NAME="Acme SSO"                       # button label
JOOBQUI_OIDC_ROLE_MAP="joobq-admins=admin,joobq-ops=operator,*=viewer"
JOOBQUI_OIDC_ALLOWED_DOMAINS=acme.io
```

Register `https://joobqui.acme.io/api/v1/auth/oidc/callback` as the redirect URI at your provider. The flow is the authorization-code flow with PKCE (S256). The role comes from the provider's groups claim (`JOOBQUI_OIDC_GROUPS_CLAIM`, default `groups`); a token without that claim never changes a role, and a role an admin set by hand is locked against SSO changes.

Options:

- `JOOBQUI_OIDC_AUTO_CREATE` (default `true`) makes an account on first sign-in.
- `JOOBQUI_OIDC_LINK_BY_EMAIL` links an existing account by email (risky; linking replaces its password and second factor).
- `JOOBQUI_OIDC_ONLY=true` leaves passwords for admins only.
- `JOOBQUI_MFA_SSO_EXEMPT=true` exempts SSO sessions from the second-factor requirement.

On a licensed deployment, single sign-on needs the Team or Enterprise tier; otherwise its routes answer `402 sso_upgrade_required`.

## 5. Check the audit log

Every state-changing call, sign-in, sign-out and sign-up is recorded: who, role, client address, action, outcome and request id, never bodies or secrets. Changes to access (tokens, roles, second factor, channels, erasure) write a `pending` intent row first and are refused with `503` if it cannot be written. Admins search the **Audit** page and export up to 10,000 events as CSV or JSON. `JOOBQUI_AUDIT_RETENTION_DAYS` (default 365) bounds how long it is kept.

Behind a reverse proxy set `JOOBQUI_CLIENT_IP_HEADER` (for example `Fly-Client-IP`), or every visitor counts as one client in the audit log and the sign-in throttles.
