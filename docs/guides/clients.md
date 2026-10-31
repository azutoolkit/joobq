---
description: Admit jobs and interact with workflow runs without starting another worker.
---

# Use clients and producers

Choose the API for the processing path you use. Core jobs, Pro workflows, and Delivery have different identities and completion models.

| Path | Producer interface | Completion |
| --- | --- | --- |
| Legacy Core jobs | Typed `Job.enqueue`, `delay`, or `batch_enqueue` | Application results, events, and queue inspection; no general result-wait client |
| Pro workflows | `JoobQPro::Workflows::Client` | `describe`, `history`, `query`, and `result` |
| Delivery preview | Explicit runtime/ledger admission | Receipts and reconciliation in a separate namespace |

## Enqueue a Core job

Load the shared initializer; do not call `forge` in the producer:

<!-- illustrative: src/enqueue_order.cr in the application from the configuration guide -->
```crystal
require "./initializers/joobq"
jid = ProcessOrderJob.enqueue(order_id: 42_i64)
puts jid
```

An ID returned by admission does not mean the handler finished. If admission raises after Redis accepted the write, the outcome may be unknown. Retrying legacy enqueue is not automatically deduplicated; carry a stable business key and reconcile the effect.

## Connect a Pro workflow client

Start the [production worker example](../production-deployment/deploy-workers.md), then run its [separate producer probe](../production-deployment/deploy-workers.md#check-it-from-a-separate-producer). `Client.new` uses the configured Redis store; it does not start orchestrators or activity workers. Construct it after loading the same store configuration as your workers.

For that example's registered `orders` workflow:

<!-- illustrative: producer code after requiring joobq_pro and configuring the shared Redis store -->
```crystal
client = JoobQPro::Workflows::Client.new
id, created = client.try_start("orders", 42_i64, id: "order-42-v1")
result = client.result(id, timeout: 10.seconds)
```

A stable run ID makes another start a no-op while that ID exists; `created` tells you whether this call created the run. Existing IDs do not validate a newly supplied payload against the original input. Reuse an ID only for the same business intent, and account for retention before relying on it permanently.

`result` polls and waits in the calling fiber. A client wait timeout does not cancel the workflow. Avoid holding a web request open for a long workflow: store the run ID and expose an application status endpoint instead.

## Inspect and interact

`describe(id)` returns current state. `history(id, after_seq: ..., limit: ...)` reads a bounded history page; the default limit is 200, so page when you need the full history. `query` evaluates a declared read-only query. `signal` appends a message and does not deduplicate repeated submissions.

`Client#register(blueprint)` publishes a definition but installs no activity handlers. Deploy workers with the matching handlers before admitting that definition. Authorize business operations before accepting a run ID or signal from an end user; Redis credentials are not tenant-level authorization.

**Next:** [Wait for approval](wait-for-approval.md), [handle failures](handle-failures.md), and [Delivery boundaries](../core/delivery.md).
