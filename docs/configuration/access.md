---
description: Separate operational authorization from dependency access and licensing.
---

# Management access and Pro credentials

Three credentials serve different purposes:

| Credential | Used for |
| --- | --- |
| Authorized Git access | Downloading the private `joobq-pro` shard during dependency installation |
| `JOOBQ_PRO_LICENSE` | Pro license configuration |
| JoobQ management tokens | Authorizing HTTP management requests |

Installing Pro does not grant an HTTP client administrator access. Setting a license does not download code into a running Core binary.

## Enable the management API deliberately

The API is disabled by default. When enabled, the baseline policy requires **at least one** configured token, and every configured token must be at least 32 bytes. Configure only the roles you need. The following example enables all three roles with independent values:

```sh
export JOOBQ_API_READER_TOKEN="$(openssl rand -hex 32)"
export JOOBQ_API_OPERATOR_TOKEN="$(openssl rand -hex 32)"
export JOOBQ_API_ADMIN_TOKEN="$(openssl rand -hex 32)"
```

These commands create temporary development credentials in your shell. Persist production credentials in your secret manager. Do not print them in support requests or commit them in `.env` files.

| Role | Intended operations |
| --- | --- |
| Reader | GET/HEAD inspection |
| Operator | Operational mutations such as supported replay actions |
| Administrator | Destructive/reset/configuration actions |

Roles are hierarchical: an operator can also read, and an administrator can perform all three roles. Use distinct token values; reusing a value for several roles makes it resolve to the highest role loaded from the environment. A reader-only configuration is valid.

Clients authenticate with an `Authorization: Bearer …` header. Keep the listener on loopback, its default, unless your deployment supplies a protected transport and network boundary. An unencrypted remote connection can expose the token. A reverse proxy must preserve authentication and restrict access.

{% hint style="info" %}
The Azu CLI's project-local adapters and the HTTP management API are different access paths. Do not assume setting an HTTP reader token makes a CLI process with application credentials read-only.
{% endhint %}

Rotate credentials with a planned client/server rollout, verify old credentials stop working, and audit which credentials each operator receives. Remote read-only monitoring should remain separate from mutation tooling.

For Pro installation and customer feature configuration, follow [Adding Pro](../introduction/adding-pro.md).
