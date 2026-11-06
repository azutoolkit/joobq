---
description: Build a typed workflow, start a run, and follow its result through the existing engine.
---

# Build and run workflows

*How-to · Pro*

## Prerequisites

- Pro installed ([Add Pro](add-pro.md)) and a development Redis.

## Steps

1. Define the activity classes and the workflow with the DSL, register it on a worker, start the worker, then start a run and read its result:

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
2. Run it:

```sh
crystal run src/order_workflow.cr
```
3. Add steps of other kinds as you need them: `parallel` and `sequence` ([Fan out and join](fan-out-and-join.md)), `wait_for` ([Wait for approval](wait-for-approval.md)), `retry_policy` ([Set retries and handle failures](handle-failures.md)), `compensation` ([Compensate with a saga](sagas-and-compensation.md)), `timer` and `child` ([Workflow DSL](../reference/workflow-dsl.md#other-executable-steps)), queries, updates, scopes and continuation ([Lifecycle controls](../reference/workflow-lifecycle-controls.md)).
4. For a deployed service, split producer and worker as in [Deploy and scale workers](deploy-workers.md).

## Verify

The program prints `Processed order 42`.

## See also

- [Workflows and sagas](../explanation/durable-workflows.md)
- [Test workflows](test-workflows.md)
