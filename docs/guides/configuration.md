---
description: Give producers, workers, and inspection tools one predictable boot configuration.
---

# Configure an application

Start with the [supported dependency graph](../introduction/compatibility.md). Then give every process the same job definitions, Redis endpoint, and queue registrations. Keep process startup separate from configuration.

## Use a shared initializer

A small application can use this layout:

```text
src/
  jobs/process_order_job.cr   # Type and perform method
  initializers/joobq.cr       # Requires jobs; configures store and queues
  enqueue_order.cr           # Requires initializer; admits work
  worker.cr                  # Requires initializer; starts workers
```

The [queue guide](queues.md) contains both registration variants. On Azu CLI v0.1.59, `azu generate joobq` creates this setup; follow the [Azu walkthrough](../quick-start/azu-application.md) before modifying its generated YAML.

Do not call `forge`, register recurring callbacks, or start a Pro worker in a shared inspection initializer. Those actions start work. CLI status and dashboard adapters load the initializer too.

## Supply Redis settings before boot

For a disposable local development instance:

```sh
export REDIS_URL=redis://127.0.0.1:6379/0
export REDIS_POOL_SIZE=20
crystal run src/worker.cr
```

`RedisStore.from_env` gives a nonempty `REDIS_URL` precedence over legacy host/port/password variables. Set environment values before configuration creates the store. Replacing a variable after a pool exists does not reconnect that pool to a different endpoint.

Production connections should use verified TLS and secret-managed credentials. See the [Redis options and defaults](../configuration/redis.md). Pool size is per configured pool, so budget across all processes and replicas.

## Choose one loading path

The framework supports programmatic configuration and YAML discovery/loading. An explicit queue initializer is straightforward; a generated YAML setup is also valid. Avoid loading one configuration and then silently replacing it in another initializer.

Environment-specific discovery and `JOOBQ_CONFIG_PATH`/`JOOBQ_CONFIG_FILE` have ordering rules; those variables are not unconditional overrides of earlier files. Check the [configuration reference](../configuration/README.md) and inspect effective queue registrations without printing credentials.

## Enable only what you need

Keep `rest_api_enabled = false` unless you need the management listener. When enabled, provide at least one distinct role token of 32 bytes or more. A reader-only token configuration is supported; see [management access](../configuration/access.md).

The configured seven-day `dead_letter_ttl` is not enforced by the released Redis DLQ implementation. Plan retention explicitly. Likewise, `config.timeout` does not kill running job fibers. Treat configuration names as API inputs, not guarantees beyond their implementation.

**Next:** [Worker lifecycle](workers.md), [clients](clients.md), and [production deployment](../production-deployment/README.md).
