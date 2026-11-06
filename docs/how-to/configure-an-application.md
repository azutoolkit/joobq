---
description: Give producers, workers, and inspection tools one predictable boot configuration.
---

# Configure an application

*How-to · Core*

## Prerequisites

- JoobQ installed ([Install JoobQ](install.md)).

## Steps

1. Put job classes and queue configuration in one initializer that both the producer and the worker require:

```text
src/
  jobs/process_order_job.cr   # Type and perform method
  initializers/joobq.cr       # Requires jobs; configures store and queues
  enqueue_order.cr           # Requires initializer; admits work
  worker.cr                  # Requires initializer; starts workers
```
   In an Azu application, `azu generate joobq` (Azu CLI 0.1.62) creates this layout ([Use JoobQ in an Azu application](use-joobq-in-azu.md)).
2. Keep `JoobQ.forge`, recurring schedules and Pro workers out of that initializer; start them in the worker entry point only.
3. Set Redis before boot; a non-empty `REDIS_URL` takes precedence over `REDIS_HOST`/`REDIS_PORT`/`REDIS_PASS`:

```sh
export REDIS_URL=redis://127.0.0.1:6379/0
export REDIS_POOL_SIZE=20
crystal run src/worker.cr
```
4. Use one loading path: either `JoobQ.configure` in code or YAML loading, not both replacing each other.
5. Leave `rest_api_enabled = false` unless you need the management API ([Secure management access](secure-management-access.md)).

## Verify

- The producer and the worker log the same Redis host and port at start.
- A job enqueued by the producer is processed by the worker.

## See also

- [Configuration](../reference/configuration.md): every setting and its default.
- [Architecture at a glance](../explanation/application-architecture.md)
