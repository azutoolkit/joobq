---
description: Run a typed order-processing job with Crystal and Redis.
---

# Quick Start

You will enqueue order `42`, see a worker process it, and stop the worker cleanly. Have Crystal **1.22.1**, Shards, and a local Redis instance ready. The short path targets about three minutes with prerequisites installed; dependency downloads and cold compilation vary by machine.

## 1. Create the project

```sh
mkdir order_worker
cd order_worker
mkdir src
```

{% code title="shard.yml" %}
```yaml
name: order_worker
version: 0.1.0

dependencies:
  joobq:
    github: azutoolkit/joobq
    version: "= 0.5.1"
```
{% endcode %}

```sh
shards install
redis-cli ping
```

Expect `PONG`. This walkthrough uses the default local Redis connection. Use a dedicated development instance; see [Redis configuration](../configuration/redis.md) for other endpoints. Commit `shard.lock` with your application.

## 2. Write the job and register its queue

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

The queue name on the job matches the registered queue. `enqueue` stores work; `forge` starts workers and waits. The handler prints a message instead of calling a real payment or mail service.

## 3. Run it

```sh
crystal run src/worker.cr
```

Among the startup logs, expect:

```text
Processed order 42
```

Press **Ctrl-C** after completion. JoobQ stops accepting work and drains its workers. Each launch of this demonstration enqueues a new job; a real producer normally lives separately from worker startup.

[Screenshot: A terminal showing the Quick Start worker starting the orders queue, printing Processed order 42, and exiting after Ctrl-C without exposing connection credentials.]

{% hint style="info" %}
The management API is deliberately off. No management token is needed for this example. A job that performs an external effect still needs [idempotency](../best-practices/idempotency.md).
{% endhint %}

**Next:** [Queues and workers](../core/queues-workers.md), or [integrate an Azu app](azu-application.md).
