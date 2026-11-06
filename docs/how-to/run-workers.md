---
description: Start the correct runtime, check progress, and stop it deliberately.
---

# Run workers

*How-to · Core · Pro*

## Prerequisites

- A shared initializer that loads the job classes and configures their queues ([Configure an application](configure-an-application.md)).

## Start Core workers

1. Write a worker entry point that requires the initializer and calls `JoobQ.forge`:

{% code title="src/worker.cr — Core entry point" %}
<!-- illustrative: entry point for an application with the shared initializer -->
```crystal
require "./initializers/joobq"
JoobQ.forge
```
{% endcode %}
2. Run it as its own process, separate from your web process:

```sh
crystal run src/worker.cr
```
   In an Azu application, `azu jobs:worker` is the CLI's own entry point; run your file directly if it starts more services.
3. To list the process on JoobQUI's Workers page, call `JoobQ::WorkerRegistry.new.start` before `forge`.

## Start Pro workflow workers

1. Create a `JoobQPro::Workflows::Worker`, register your blueprints and call `start`; it does not block, so keep the process alive yourself, as the [production worker](deploy-workers.md) does.
2. Pass `scheduler: true` (the default) on at least one worker if you use workflow schedules.

## Run with several threads

```sh
mkdir -p bin
crystal build src/worker.cr --release -Dpreview_mt -o bin/worker
CRYSTAL_WORKERS=4 ./bin/worker
```

## Verify

- The log has a `JoobQ starting <queue> queue...` line for each of your queues.
- A job enqueued from a separate producer completes.

## See also

- [Workers and concurrency](../explanation/workers-and-concurrency.md)
- [Reliability and recovery](../explanation/reliability-and-recovery.md): what a restart recovers.
