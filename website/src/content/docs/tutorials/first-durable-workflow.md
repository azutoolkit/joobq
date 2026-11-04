---
title: Your First Durable Workflow
description: Build an order-fulfilment saga with JoobQ Pro's typed DSL, signal it, query it, and watch a failure undo earlier steps.
order: 2
product: pro
---

You will define a workflow that reserves stock, charges a card (with retries), waits for a manager's approval, packs the order and notifies the customer. When packing fails, the engine refunds the charge and releases the stock. You need the [JoobQ Pro dependency](https://github.com/azutoolkit/joobq/blob/master/docs/introduction/adding-pro.md) (a private shard: your Git credentials must be able to read `azutoolkit/joobq-pro`) and a Redis you can throw away.

```yaml
# shard.yml
dependencies:
  joobq_pro:
    github: azutoolkit/joobq-pro
    version: "= 0.2.2"
```

Pro pins the JoobQ core revision it was tested with; do not add a different `joobq` constraint next to it. The typed DSL is available since **Pro v0.2.2** and is an authoring preview; constructor-based definitions keep working.

## 1. Write the activities

An activity is a class with `perform(input, context)`. The input is a `JSON::Serializable` type; the return value becomes the step's output in the run's history.

```crystal
# src/order_fulfilment.cr
require "joobq_pro"
include JoobQPro::Workflows::DSL

struct Order
  include JSON::Serializable
  getter order : String = "demo"
  getter amount : Int32 = 100
  getter fault : String? = nil   # "charge" fails one attempt, "pack" fails for good
end

class ReserveInventory
  def perform(input : Order, ctx : JoobQPro::Workflows::ActivityContext) : JSON::Any
    JSON.parse({reservation: "res-#{input.order}"}.to_json)
  end
end

class ReleaseInventory
  def perform(input : JSON::Any, ctx : JoobQPro::Workflows::ActivityContext) : String
    "released"
  end
end

class ChargeCard
  def perform(input : Order, ctx : JoobQPro::Workflows::ActivityContext) : JSON::Any
    raise "payment gateway timed out" if input.fault == "charge" && ctx.attempt == 1
    JSON.parse({charge: "ch-#{input.order}-#{ctx.attempt}", amount: input.amount}.to_json)
  end
end

class RefundCard
  def perform(input : JSON::Any, ctx : JoobQPro::Workflows::ActivityContext) : String
    "refunded"
  end
end

class PackItems
  def perform(input : Order, ctx : JoobQPro::Workflows::ActivityContext) : String
    if input.fault == "pack"
      raise JoobQPro::Workflows::NonRetryableError.new("warehouse reported the item is out of stock")
    end
    "packed"
  end
end

class NotifyCustomer
  def perform(input : Order, ctx : JoobQPro::Workflows::ActivityContext) : String
    "notified #{input.order}"
  end
end
```

In a real activity, pass `ctx.dedupe_key` to the payment or mail service as its idempotency key: an activity can run again after a crash or a redelivery.

## 2. Declare the workflow

```crystal
OrderFulfilment = workflow "order-fulfilment", timeout: 1.hour do
  order = {order: input(:order), amount: input(:amount), fault: input(:fault)}
  query "progress", ref("steps")

  step :reserve_inventory, ReserveInventory, input: order,
    compensate: compensation(ReleaseInventory)
  step :charge_card, ChargeCard, input: order,
    retry: retry_policy(attempts: 3, initial: 1500.milliseconds),
    compensate: compensation(RefundCard)
  wait_for :manager_approval, signal: :approve, timeout: 10.minutes
  step :pack_items, PackItems, input: order
  timer :cool_down, for: 2.seconds
  step :notify_customer, NotifyCustomer, input: order
end
```

`workflow` returns a validated blueprint without touching Redis. Steps run top to bottom; `parallel do ... end` and `sequence do ... end` add branches. `input(:order)` and `ref("steps")` are expressions the engine resolves from the run's state.

## 3. Start a worker and a run

```crystal
JoobQ.configure { |config| config.rest_api_enabled = false }
worker = JoobQPro::Workflows::Worker.new(activity_workers: 2, orchestrators: 1)
worker.register(OrderFulfilment).start

id = worker.client.start("order-fulfilment", {order: "A-1042", amount: 4999})
sleep 2.seconds
puts worker.client.query(id, "progress")          # steps so far
worker.client.signal(id, "approve", {by: "ops"})  # releases manager_approval
puts worker.client.result(id, timeout: 30.seconds)

JoobQPro.shutdown
JoobQ.shutdown
```

`start` returns the run id (pass `id:` to choose one; starting an existing id is a no-op). `result` waits for the output and raises `WorkflowFailed` if the run fails.

## 4. Watch the saga undo itself

Start a second run with `{order: "B-7", amount: 10, fault: "pack"}` and approve it. `pack_items` raises a `NonRetryableError`, so the workflow fails, and the completed steps that have a `compensate:` are undone one at a time, newest first: `RefundCard`, then `ReleaseInventory`. Read the run's history to see it:

```crystal
worker.client.history(id).each { |event| puts "#{event.seq} #{event.type} #{event.step_id}" }
```

You will see `StepFailed` for `pack_items`, then `CompensationStarted` events for `charge_card` and `reserve_inventory`, and `WorkflowFailed`. A run with `fault: "charge"` shows `StepFailed` and `StepRetrying` for the first charge attempt and then carries on.

## What is durable here

Each change is an event appended to the run's history in Redis by one Lua script, together with its effects (the next activity, timers, deadlines). State is always a fold of that history, so a worker that crashes loses nothing Redis kept; another worker picks the run up. See [Workflows, event history & sagas](/docs/explanation/workflows-event-history-and-sagas).

## Next

- [Schedules & alerts](/docs/tutorials/schedules-and-alerts)
- [Operate workflows in production](/docs/how-to/operate-workflows-in-production)
