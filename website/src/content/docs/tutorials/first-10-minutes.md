---
title: Your First 10 Minutes with JoobQ
description: Install the shard, define a typed job, run a worker, and watch a failing job reach the dead-letter set.
order: 1
product: oss
---

You will add JoobQ to a Crystal project, enqueue an order job, see a worker process it, make a job fail until its retries run out, and stop the worker cleanly. You need **Crystal 1.22** or newer, Shards, and a Redis server you can throw away (version 5 or newer).

## 1. Create the project

```bash
mkdir order_worker && cd order_worker && mkdir src
```

Add JoobQ to `shard.yml`. The examples on this site were checked against `0.5.1`; pin the version you test with and commit `shard.lock`.

```yaml
name: order_worker
version: 0.1.0

dependencies:
  joobq:
    github: azutoolkit/joobq
    version: "= 0.5.1"
```

```bash
shards install
redis-cli ping   # expect PONG
```

JoobQ connects to `localhost:6379` by default. Point it elsewhere with `REDIS_URL` (`redis://`, `rediss://` for TLS, or `unix:///path.sock`) or `REDIS_HOST` / `REDIS_PORT` / `REDIS_PASS`.

## 2. Write a job and register its queue

A job is a struct that includes `JoobQ::Job` and implements `perform`. Its `@queue` must name a queue you register in `JoobQ.configure`.

```crystal
# src/worker.cr
require "joobq"

struct ProcessOrderJob
  include JoobQ::Job

  @queue   = "orders"
  @retries = 2

  getter order_id : Int64

  def initialize(@order_id : Int64)
  end

  def perform
    raise "payment gateway timeout for order #{order_id}" if order_id == 13
    puts "Processed order #{order_id}"
  end
end

JoobQ.configure do |config|
  config.rest_api_enabled = false
  queue "orders", 2, ProcessOrderJob
end

ProcessOrderJob.enqueue(order_id: 42_i64)
ProcessOrderJob.enqueue(order_id: 13_i64)            # fails every time
ProcessOrderJob.delay(for: 30.seconds, order_id: 7_i64)

JoobQ.forge
```

`enqueue` stores the job in Redis. `delay(for:)` (or `enqueue_at`) makes it eligible later. `JoobQ.forge` starts the workers and keeps the process running. The REST API is switched off here so nothing listens on a port.

## 3. Run it

```bash
crystal run src/worker.cr
```

Among the start-up logs you will see `Processed order 42`, and half a minute later `Processed order 7`.

Order 13 raises. The retry middleware puts it back with exponential backoff (one second, doubling per attempt), and after the initial attempt plus `@retries` retries it moves to the **dead-letter set** with its error, class and retry count.

## 4. Stop it cleanly

Press **Ctrl-C**. `forge` traps `SIGTERM`, `SIGINT` and `SIGHUP`, stops claiming work, waits for running jobs (15 seconds by default) and puts back any job that outlives the deadline. The exit status says how it went: `0` clean, `3` jobs were put back, `1` a second signal cut the shutdown short.

> A job can run more than once: after a crash, a redelivery, or when shutdown puts it back. Make `perform` safe to repeat, for example with an idempotency key on the external call.

## 5. Look at the dead letter

The dead-letter set is a Redis sorted set (`joobq:dead_letter`). Inspect and redrive entries:

- from the **JoobQUI console** (Dead letters page, one at a time or in bulk), see [Triage & redrive dead letters](/docs/how-to/triage-and-redrive-dead-letters);
- from an Azu app with the Azu CLI: `azu jobs:dlq --queue orders --json`, then `azu jobs:retry --queue orders --limit 1 --dry-run`.

Fix the cause before you redrive: a redriven job runs the same code with the same arguments.

## Next

- Turn this job into a step of a [durable workflow](/docs/tutorials/first-durable-workflow).
- Read the [configuration reference](/docs/reference/configuration-and-env-vars) for retries, timeouts and Redis settings.
