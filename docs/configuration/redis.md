---
description: Connect every producer and worker to the same verified Redis service.
---

# Redis connections and resilience

`JoobQ::RedisStore.from_env` accepts `REDIS_URL` or the legacy host/port/password variables. A supplied URL takes precedence in that loader. Prefer one configuration style per deployment.

{% tabs %}
{% tab title="Local development" %}
```sh
export REDIS_HOST=127.0.0.1
export REDIS_PORT=6379
crystal run src/worker.cr
```
{% endtab %}
{% tab title="Verified TLS" %}
```sh
# Supply REDIS_URL through your secret manager: rediss://user:password@host:port/db
export REDIS_TLS_VERIFY=true
export REDIS_CA_FILE=/run/secrets/redis-ca.pem
crystal run src/worker.cr
```
Keep the hostname consistent with the server certificate. Do not disable certificate verification to work around a trust-store problem.
{% endtab %}
{% endtabs %}

| Variable | Default | Purpose |
| --- | --- | --- |
| `REDIS_URL` | Unset | Redis URI, including database and optional TLS/authentication |
| `REDIS_HOST` / `REDIS_PORT` | `localhost` / `6379` | Legacy endpoint |
| `REDIS_PASS` | Unset | Legacy password |
| `REDIS_POOL_SIZE` | `500` | Maximum connections per configured pool |
| `REDIS_POOL_TIMEOUT` | `2.0` | Pool checkout timeout in seconds |
| `REDIS_CONNECT_TIMEOUT` | `5.0` | Connection establishment timeout in seconds |
| `REDIS_COMMAND_TIMEOUT` | `5.0` | Command I/O timeout in seconds |
| `REDIS_OPERATION_TIMEOUT` | `5.0` | Bounded retry/operation budget in seconds |
| `REDIS_TLS_VERIFY` | `true` | Verify TLS certificates |
| `REDIS_CA_FILE` | Unset | Optional CA certificate file |

An operation can fail after Redis accepted it but before its reply arrived. Treat that as an unknown outcome. Reconcile with stable identifiers where supported; retrying an external effect blindly can duplicate it.

## Persistence is a deployment decision

Redis acknowledgment is not a promise that a write survived every machine, storage, or failover failure. Choose AOF/RDB settings, replication, backups, retention, and recovery procedures for your recovery-point and recovery-time objectives. Avoid eviction policies that silently remove queue or receipt keys.

```mermaid
flowchart LR
  App[Producer] --> Pool[Bounded connection pool]
  Pool --> Redis[(Redis primary)]
  Worker[Workers] --> Redis
  Redis --> Replica[(Replica)]
  Redis --> Backup[Backups]
  Backup --> Restore[Isolated restore rehearsal]
```

Cluster key placement, proxy behavior, managed failover, and ACL permissions need validation with the exact Lua scripts and commands your enabled features use. A successful `PING` alone does not validate those paths.

**Next:** [Recovery and migration](../best-practices/recovery.md).
