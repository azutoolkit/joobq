---
description: Run your first typed background job with Crystal and Redis, in under five minutes.
---

# Your first background job

*Tutorial · Core*

You will write a job that processes order 42, run a worker that performs it, and stop the worker cleanly. You need Crystal 1.22 or newer, Shards, and a Redis server running on `localhost:6379`.

{% stepper %}
{% step %}
## Create the project

```sh
mkdir -p order_worker/src
cd order_worker
```

Create `shard.yml`:

{% code title="shard.yml" %}
```yaml
name: order_worker
version: 0.1.0

dependencies:
  joobq:
    github: azutoolkit/joobq
    version: "= 0.5.6"
```
{% endcode %}

Install it:

```sh
shards install
```

You should see:

```
I: Resolving dependencies
I: Fetching https://github.com/azutoolkit/joobq.git
I: Fetching https://github.com/stefanwille/crystal-redis.git
I: Fetching https://github.com/kostya/cron_parser.git
I: Fetching https://github.com/ysbaddaden/pool.git
I: Installing pool (0.2.4)
I: Installing redis (2.9.1)
I: Installing cron_parser (0.4.0)
I: Installing joobq (0.5.6)
I: Writing shard.lock
```
{% endstep %}

{% step %}
## Check that Redis answers

```sh
redis-cli ping
```

You should see:

```
PONG
```
{% endstep %}

{% step %}
## Write the job

Create `src/worker.cr`:

{% code title="src/worker.cr" %}
<!-- example: core/first_job.cr -->
```crystal
require "joobq"

struct ProcessOrderJob
  include JoobQ::Job

  @queue = "orders"
  getter order_id : Int64

  def initialize(@order_id : Int64)
  end

  def perform
    puts "Processed order #{order_id}"
  end
end

JoobQ.configure do |config|
  config.rest_api_enabled = false
  queue "orders", 2, ProcessOrderJob
end

ProcessOrderJob.enqueue(order_id: 42_i64)
JoobQ.forge
```
{% endcode %}

The job's `@queue` is `orders`, the same name the `queue` line registers with two workers.
{% endstep %}

{% step %}
## Run the worker

```sh
crystal run src/worker.cr
```

The first build takes a few seconds. Among JoobQ's log lines you should see:

```
Processed order 42
```
{% endstep %}

{% step %}
## Stop the worker

Press **Ctrl-C**. The last log line should be:

```
INFO - JoobQ stopped -- abandoned_jobs: 0
```

The worker finished its job before stopping, so nothing was put back on the queue.
{% endstep %}
{% endstepper %}

You have run a typed job through Redis and stopped its worker cleanly. On the machine these outputs come from, the whole tutorial took about 17 seconds after Crystal was installed: 2 seconds for `shards install`, 15 for the first build and run.

## Next steps

- [Connect to JoobQUI and recover a failed job](https://joobq-website.onrender.com/docs/tutorials/01-first-10-minutes): see the job in the console.
- [Jobs and payloads](../explanation/job-lifecycle.md): what the job looks like in Redis.
- [Write and enqueue jobs](../how-to/write-and-enqueue-jobs.md): enqueue from your application.
