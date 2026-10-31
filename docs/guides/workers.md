---
description: Start the correct runtime, check progress, and stop it deliberately.
---

# Run workers

A producer stores work. A worker executes it. Run them as separate processes so an HTTP restart, a CLI inspection, or a new order does not accidentally start another consumer.

## Start Core workers

After creating the shared initializer in the [configuration guide](configuration.md):

{% code title="src/worker.cr — Core entry point" %}
<!-- illustrative: entry point for an application with the shared initializer -->
```crystal
require "./initializers/joobq"
JoobQ.forge
```
{% endcode %}

```sh
crystal run src/worker.cr
```

`forge` starts configured queue workers, delayed-job processing, the expired-job reaper, and configured schedulers. It also starts the management API if enabled, installs termination handlers by default, and blocks until shutdown.

If it reports zero queues, check job loading and registration before tuning Redis. A producer can enqueue successfully while no compatible consumer is running.

In an Azu application, `azu jobs:worker` provides the CLI's worker entry point. It does not execute a customized `src/worker.cr` verbatim. Run your file directly if it owns additional services.

## Start Pro workflow workers

Use `JoobQPro::Workflows::Worker`, register blueprints, and call `start`. This starts its orchestrators, reconciler, activity transport, and optional workflow scheduler. It does not block your main fiber or install your application's signal handlers.

The complete [production worker](../production-deployment/deploy-workers.md) keeps the process alive, receives signals, stops Pro before Core, and runs a separate producer probe. Its `scheduler: false` disables workflow schedule firing, not timer/deadline reconciliation. Enable a workflow scheduler if you create workflow schedules.

## Verify progress

Watch completed business work, backlog age, errors, and worker presence. A startup log, open Redis connection, or empty queue is not enough. `WorkerRegistry` exists but is not automatically started by `forge` in the documented releases; a worker list can therefore be empty while jobs complete.

For multithreading on Crystal 1.22.1:

```sh
mkdir -p bin
crystal build src/worker.cr --release -Dpreview_mt -o bin/worker
CRYSTAL_WORKERS=4 ./bin/worker
```

Choose threads from allocated CPUs. Set queue workers and `worker_batch_size` separately, then measure downstream saturation.

## Stop and recover

Core's default signal handlers initiate a bounded shutdown. Work still running at the deadline may be requeued while its original fiber finishes an external effect. The exit status is `3` when Core reports abandoned jobs; inspect shutdown logs too.

A SIGKILL cannot run that drain. Legacy startup reclaims only one processing member per queue start and can reclaim another process's work. Follow the [recovery limits and procedure](../best-practices/recovery.md), and use duplicate-safe handlers.

**Next:** [Deploy workers](../production-deployment/deploy-workers.md) and [operate upgrades](../production-deployment/operate-and-upgrade.md).
