---
description: Generate jobs and inspect the same application configuration from the CLI.
---

# Use JoobQ in an Azu application

*How-to · Core*

## Prerequisites

- An Azu application with Azu CLI 0.1.62, and `joobq` (or `joobq_pro`) in its `shard.yml` with `shards install` run; the generator writes files but installs nothing.

## Steps

1. Generate the JoobQ setup, check it, and start a worker:

```sh
azu generate joobq --queue orders --workers 2
azu jobs:status --queue orders --json
azu jobs:worker --queues orders --workers 2
```
2. Require `./initializers/joobq` from your application's entry point.
3. Enqueue the generated example job from a small producer, and run it in another terminal with `crystal run src/enqueue_example.cr`:

<!-- illustrative: src/enqueue_example.cr inside the generated application -->
```crystal
require "./initializers/joobq"
ExampleJob.enqueue(message: "Hello, JoobQ!")
```
4. Generate your own job:

```sh
azu generate job ProcessOrder order_id:int64
```
   Set its `@queue = "orders"`, implement `perform`, and register it in `src/initializers/joobq.cr` before the configuration loads:

<!-- illustrative: after requiring job files, before loading configuration -->
```crystal
JoobQ::QueueFactory.register_job_type(ProcessOrderJob)
```
   Change the `orders` queue's `job_class` in the environment YAML from `ExampleJob` to `ProcessOrderJob`, then restart the workers.
5. Run the application and open its Jobs section, or `azu joobq` for the terminal dashboard:

```sh
azu dev
```
6. If your inspection initializer lives elsewhere, pass it with `--boot`; it must not call `JoobQ.forge` or start a server:

```sh
azu jobs:status --boot src/initializers/joobq.cr --queue orders --json
azu joobq --boot src/initializers/joobq.cr
```
   Existing files are not overwritten unless you pass `--force`.

## Verify

`azu jobs:status --queue orders --json` lists the `orders` queue, and the worker logs `Job completed successfully` for the example job.

## See also

- [Azu CLI and terminal dashboard](../reference/azu-cli-and-terminal.md)
