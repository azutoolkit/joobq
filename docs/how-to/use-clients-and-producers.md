---
description: Admit jobs and interact with workflow runs without starting another worker.
---

# Use clients and producers

*How-to · Core · Pro*

## Prerequisites

- The shared initializer, required by the producer, without `JoobQ.forge` ([Configure an application](configure-an-application.md)).

## Enqueue a Core job

<!-- illustrative: src/enqueue_order.cr in the application from the configuration guide -->
```crystal
require "./initializers/joobq"
jid = ProcessOrderJob.enqueue(order_id: 42_i64)
puts jid
```
Store the returned `jid` with your record; it is not a completion receipt, and a second `enqueue` is not deduplicated.

## Start and follow a Pro workflow

1. Create a `JoobQPro::Workflows::Client` after loading the same store configuration as the workers; it starts no workers.
2. Start the run with a stable id, so a second start with that id is a no-op (`try_start` returns whether this call created it):

<!-- illustrative: producer code after requiring joobq_pro and configuring the shared Redis store -->
```crystal
client = JoobQPro::Workflows::Client.new
id, created = client.try_start("orders", 42_i64, id: "order-42-v1")
result = client.result(id, timeout: 10.seconds)
```
3. Store the run id; `result` waits in the calling fiber and its timeout does not cancel the run, so expose a status endpoint rather than holding a request open.
4. Read the run with `describe(id)`, `history(id, after_seq: ..., limit: ...)` (default limit 200), `query(id, name)`; send a signal with `signal(id, name, payload)`.
5. Authorize the caller before you accept a run id or signal from an end user.

## Verify

`client.describe(id).status` shows the run, and `client.result(id)` returns its output when it completes.

## See also

- [Workflows and sagas](../explanation/durable-workflows.md)
- [Workflow lifecycle controls](../reference/workflow-lifecycle-controls.md)
