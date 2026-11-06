---
description: Connect every producer and worker to the same verified Redis service.
---

# Connect to Redis

*How-to · Core*

## Prerequisites

- The Redis endpoint, and for TLS its CA certificate if it is not publicly trusted.

## Steps

1. Set the connection before the process configures JoobQ, either with host and port or with a URL. A non-empty `REDIS_URL` takes precedence over `REDIS_HOST`, `REDIS_PORT` and `REDIS_PASS`.

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
Keep the hostname the same as the one on the server certificate; do not turn verification off.
{% endtab %}
{% endtabs %}

2. Adjust the pool and timeouts if you need to:

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

3. Start the worker.

## Verify

- The worker's log shows `Redis store initialized` with the host and port you set, and no connection errors.
- A job you enqueue from a producer with the same settings is processed.

## See also

- [Set up Redis and recovery](redis-and-recovery.md): persistence and backups.
- [Reliability and recovery](../explanation/reliability-and-recovery.md): unknown outcomes and what persistence protects.
