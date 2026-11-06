---
description: Pause a workflow for an external decision without holding an activity open.
---

# Wait for approval

*How-to · Pro*

## Prerequisites

- Pro installed ([Add Pro](add-pro.md)) and a development Redis.

## Steps

1. Add a `wait_for` step with a timeout, pass the signal's payload to the next step with `output(:approval, :approved)`, and declare a query for the decision:

{% code title="src/review_order.cr" %}
<!-- example: pro/approval_workflow.cr -->
```crystal
require "joobq_pro"
include JoobQPro::Workflows::DSL

struct ReviewInput
  include JSON::Serializable
  getter order_id : Int64
  getter approved : Bool
end

class CompleteApprovedOrder
  def perform(input : ReviewInput, context : JoobQPro::Workflows::ActivityContext) : String
    raise JoobQPro::Workflows::NonRetryableError.new("Order rejected") unless input.approved
    "Approved order #{input.order_id}"
  end
end

OrderReview = workflow "order-review", timeout: 1.minute do
  wait_for :approval, signal: :approve, timeout: 30.seconds
  step :complete, CompleteApprovedOrder,
    input: {order_id: input(:order_id), approved: output(:approval, :approved)}
  query :approval, output(:approval)
end

JoobQ.configure { |config| config.rest_api_enabled = false }
worker = JoobQPro::Workflows::Worker.new(activity_workers: 1, orchestrators: 1, scheduler: false)
begin
  worker.register(OrderReview).start
  id = worker.client.start("order-review", {order_id: 42_i64})
  raise "Signal was not accepted" unless worker.client.signal(id, "approve", {approved: true})
  result = worker.client.result(id, timeout: 10.seconds)
  raise "Unexpected result" unless result["complete"].as_s == "Approved order 42"
  raise "Approval missing" unless worker.client.query(id, "approval")["approved"].as_bool
  puts result["complete"].as_s
ensure
  JoobQPro.shutdown
  JoobQ.shutdown
end
```
{% endcode %}
2. Run it (the example sends its own approval):

```sh
crystal run src/review_order.cr
```
3. In your application, store the run id with the order and send the signal from an authenticated endpoint after checking that the caller may approve: `client.signal(id, "approve", {approved: true})`.
4. Handle a declined decision or a timeout as a failure of the run.

## Verify

The program prints `Approved order 42`, and `client.query(id, "approval")` returns the recorded decision.

## See also

- [Workflows and sagas](../explanation/durable-workflows.md)
- [Build a durable workflow and saga](https://joobq-website.onrender.com/docs/tutorials/02-your-first-durable-workflow)
