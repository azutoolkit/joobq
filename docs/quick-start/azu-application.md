---
description: Generate jobs and inspect the same application configuration from the CLI.
---

# Use JoobQ in an Azu application

Use Azu CLI `v0.1.59` in an existing application. Its generator creates environment-specific configuration, a registered example job, and a worker entry point.

First, install the [Core quick-start dependency](README.md) or the [compatible Pro pair](../introduction/adding-pro.md), run `shards install`, and require `./initializers/joobq` from your application entry point after generating it. The generator writes files; it does not install dependencies.

```sh
azu generate joobq --queue orders --workers 2
azu jobs:status --queue orders --json
azu jobs:worker --queues orders --workers 2
```

The generated `ExampleJob` already targets `orders`. To admit a demonstration job, create a small producer file:

<!-- illustrative: src/enqueue_example.cr inside the generated application -->
```crystal
require "./initializers/joobq"
ExampleJob.enqueue(message: "Hello, JoobQ!")
```

Run `crystal run src/enqueue_example.cr` in another terminal. Existing files require an explicit `--force` decision; do not overwrite an initializer you have customized.

## Add your own job

```sh
azu generate job ProcessOrder order_id:int64
```

This creates `ProcessOrderJob`. Set its `@queue = "orders"`, implement `perform`, and register it **before configuration is loaded** in `src/initializers/joobq.cr`:

<!-- illustrative: after requiring job files, before loading configuration -->
```crystal
JoobQ::QueueFactory.register_job_type(ProcessOrderJob)
```

Change the `orders` queue's `job_class` in the environment YAML from `ExampleJob` to `ProcessOrderJob`. Update the initializer's fallback `queue_configs` entry too, if you use that fallback. This replaces the example consumer; use a separate queue if you want both job types. Stop and restart workers after changing registrations. Then enqueue `ProcessOrderJob.enqueue(order_id: 42_i64)` from code that loads the initializer.

## Inspect the application

Run the web application in another terminal:

```sh
azu dev
```

Open the Jobs section for queue activity. `azu joobq` opens the standalone terminal dashboard. The dashboard loads the configured job classes through an application-side adapter; it does not start workers for you.

## Keep boot and execution separate

The default inspection boot file is `src/initializers/joobq.cr`. It must configure jobs and stores without calling `JoobQ.forge` or starting an HTTP server. Use `--boot` when your application needs a different initializer.

```sh
azu jobs:status --boot src/initializers/joobq.cr --queue orders --json
azu joobq --boot src/initializers/joobq.cr
```

A custom `src/worker.cr` is a separate entry point. Run it directly when you need its custom startup logic; do not assume `azu jobs:worker` executes it verbatim.

[Screenshot: Two terminals, one running azu jobs:worker for the orders queue and one running azu dev with Jobs selected, showing the same queue, completion counts, and an unavailable worker registry unless explicitly enabled.]

**Next:** [CLI and terminal management](../pro/management.md). For the complete generated application guide, see [Azu CLI](https://azutopia.gitbook.io/azu-cli).
