---
description: Build a typed workflow, start a run, and follow its result through the existing engine.
---

# Build and run workflows

Use a workflow when several operations need explicit ordering, waits, and recovery. A **definition** describes the graph; a **run** is one execution with its own ID and history; an **activity** is the Crystal code that performs an effect.

This guide targets **Pro v0.2.2**, which includes the preview DSL. Install the [compatible Pro dependency graph](../introduction/adding-pro.md) and start development Redis first. Existing constructors remain supported.

## Run a complete example

This program registers one typed activity, starts a run, checks its result, and shuts down. It demonstrates execution without changing a real order database.

{% code title="src/order_workflow.cr" %}
<!-- example: pro/first_workflow.cr -->
```crystal
require "joobq_pro"
include JoobQPro::Workflows::DSL

struct OrderInput
  include JSON::Serializable
  getter order_id : Int64
end

class ProcessOrder
  def perform(input : OrderInput, context : JoobQPro::Workflows::ActivityContext) : String
    "Processed order #{input.order_id}"
  end
end

ProcessOrderWorkflow = workflow "process-order", timeout: 1.minute do
  step :process, ProcessOrder
end

JoobQ.configure { |config| config.rest_api_enabled = false }
worker = JoobQPro::Workflows::Worker.new(activity_workers: 1, orchestrators: 1, scheduler: false)
begin
  worker.register(ProcessOrderWorkflow).start
  id = worker.client.start("process-order", {order_id: 42_i64})
  result = worker.client.result(id, timeout: 10.seconds)
  raise "Unexpected workflow result" unless result["process"].as_s == "Processed order 42"
  puts result["process"].as_s
ensure
  JoobQPro.shutdown
  JoobQ.shutdown
end
```
{% endcode %}

```sh
crystal run src/order_workflow.cr
```

Expect `Processed order 42`. The example intentionally combines producer and worker in one short program. Use the separate [worker entry point and producer probe](../production-deployment/deploy-workers.md) for a deployed service.

## Understand the boundaries

1. `workflow` builds and validates a blueprint locally. It does not connect to Redis, construct the activity, or execute `perform`.
2. `worker.register` installs typed handlers and publishes the serialized definition.
3. `worker.start` starts processing. It returns without keeping the main fiber alive by itself.
4. `client.start` admits a run and returns its ID. Store that ID with the business record.
5. `client.result` waits for completion and returns JSON output keyed by step ID. A non-success terminal state raises `WorkflowFailed`; a client wait timeout does not cancel the run.

Omitted step input is the original workflow input. Passing an earlier result is always explicit with `output(:step)` or `output(:step, :field)`. Input deserialization happens when the worker invokes the activity; a graph-valid reference does not prove an arbitrary JSON field has the expected type.

## Add the behavior you need

| Need | Use | Guide |
| --- | --- | --- |
| Ordered work | Consecutive `step` declarations | [DSL reference](../pro/workflow-dsl/reference.md) |
| Independent branches and a join | `parallel`, with `sequence` for an ordered branch | [Fan-out and join](../design-patterns/fan-out-and-join.md) |
| An external decision | `wait_for` and `client.signal` | [Wait for approval](wait-for-approval.md) |
| A durable pause | `timer` | [Step reference](../pro/workflow-dsl/reference.md#other-executable-steps) |
| Transient failure recovery | `retry_policy`; attempts include the first | [Handle failures](handle-failures.md) |
| Undo an earlier business effect | `compensation` | [Sagas](../design-patterns/sagas.md) |
| A sub-process with its own run | `child` naming a registered workflow | [DSL reference](../pro/workflow-dsl/reference.md#other-executable-steps) |
| Queries, updates, scopes, or continuation | Existing lifecycle helpers | [Lifecycle controls](../pro/workflow-dsl/lifecycle.md) |

Native Crystal branches and loops run during definition construction. Use `only_if:` and declarative references for decisions that depend on a run's input. Workflows remain serialized graphs, not durable execution of arbitrary Crystal closures.

## Make effects safe to repeat

Retries, timeouts, and recovery can cause another attempt. `ActivityContext#dedupe_key` is stable for a run and step, but a new run has a different key. Use a business idempotency key when the same effect must be recognized across runs. A timeout records state; it cannot forcibly stop a running Crystal fiber or cancel a remote payment.

Compensation is another fallible operation. Inspect `compensation_incomplete` and reconcile unresolved effects. The default activity transport is the legacy Core queue; Delivery is a separate opt-in configuration, not something enabling the DSL turns on.

## Inspect, test, and evolve

Use [client APIs](clients.md) for state, paged history, queries, and results. Test the graph without workers, then exercise behavior with isolated Redis using the [workflow testing guide](test-workflows.md).

A running workflow retains its persisted definition; registering a changed blueprint does not replace it. Its handlers still come from deployed code. Preserve aliases, keep compatible workers available, and review [definition migration](../pro/workflow-dsl/migration.md) and [deployment limits](../production-deployment/operate-and-upgrade.md) before rollout.
