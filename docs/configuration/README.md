---
description: Keep queue definitions, environment settings, and deployment secrets separate.
---

# Configuration

Configure producers and workers from the same initializer. Both must agree on Redis, queue names, job types, and serialized fields. Keep the initializer free of server startup; run `JoobQ.forge` only in the worker entry point.

## Queue defaults

| Setting | Core baseline default | Meaning |
| --- | --- | --- |
| `default_queue` | `"default"` | Default queue name; still register a concrete job type |
| `retries` | `3` | Retry budget after the initial attempt |
| `expires` | `3.days` | Job age limit |
| `timeout` | `2.seconds` | Configuration value; **not** a universal cancellation deadline for arbitrary handler code |
| `worker_batch_size` | `10` | Maximum in-flight claims per legacy worker loop, also limiting each fetch |
| `failed_ttl` | `7.days` | Configuration value; no failed-record expiry enforcement in these baselines |
| `dead_letter_ttl` | `7.days` | Configuration value; the Redis DLQ writer does not enforce this TTL |
| `rest_api_enabled` | `false` | Management listener |
| `stats_enabled` | `true` | Core statistics tracking |

The baseline timeout middleware checks expiration before invoking the job. Put deadlines on HTTP, SQL, and other blocking operations inside your handler. Do not rely on `config.timeout` to stop a payment request already in flight.

## Where configuration comes from

Core can discover YAML files in project, configuration, user, and system locations. Environment-specific files are considered first. `JOOBQ_ENV`, `RACK_ENV`, and `CRYSTAL_ENV` participate in that lookup. `JOOBQ_CONFIG_PATH` and `JOOBQ_CONFIG_FILE` are candidates in the discovery list; they do not universally override an earlier matching file.

Explicit initializer configuration is easiest to audit. If you choose YAML loading or environment override helpers, use one deliberate loading path and test its effective values. Avoid having multiple initializers replace the store or queue registry independently.

{% hint style="warning" %}
Never log a complete Redis URL, password, management token, license, or job payload to explain configuration. Log the endpoint host, queue names, enabled features, and connection outcome instead.
{% endhint %}

Continue with [Redis connections](redis.md), [concurrency and shutdown](concurrency.md), and [management access](access.md).
