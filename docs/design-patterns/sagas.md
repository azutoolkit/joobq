---
description: Recover from a later failure with explicit compensating operations.
---

# Sagas

A reservation succeeds, then payment fails. You cannot roll both systems back with one database transaction. A saga records an explicit compensation—such as releasing the reservation—and runs it when the workflow unwinds.

This **Pro v0.2.2** demo deliberately declines payment. Its in-memory flag only makes compensation visible in the example; it is not a durable inventory implementation.

{% code title="src/compensated_checkout.cr" %}
<!-- example: pro/compensation_workflow.cr -->
```crystal
require "joobq_pro"
include JoobQPro::Workflows::DSL

# A visible test effect, not a durable inventory database.
module DemoInventory
  RELEASED = Atomic(Bool).new(false)
end

class ReserveInventory
  def perform(order_id : Int64, context : JoobQPro::Workflows::ActivityContext) : Int64
    order_id
  end
end

class ReleaseInventory
  def perform(reservation_id : Int64, context : JoobQPro::Workflows::ActivityContext) : Int64
    DemoInventory::RELEASED.set(true)
    reservation_id
  end
end

class DeclinePayment
  def perform(order_id : Int64, context : JoobQPro::Workflows::ActivityContext) : String
    raise JoobQPro::Workflows::NonRetryableError.new("Card declined")
  end
end

Checkout = workflow "compensated-checkout", timeout: 1.minute do
  step :reserve, ReserveInventory,
    compensate: compensation(ReleaseInventory, input: output(:reserve))
  step :charge, DeclinePayment
end

JoobQ.configure { |config| config.rest_api_enabled = false }
worker = JoobQPro::Workflows::Worker.new(activity_workers: 1, orchestrators: 1, scheduler: false)
begin
  worker.register(Checkout).start
  id = worker.client.start("compensated-checkout", 42_i64)
  begin
    worker.client.result(id, timeout: 10.seconds)
    raise "Expected payment failure"
  rescue error : JoobQPro::Workflows::WorkflowFailed
    raise "Unexpected failure" unless error.failure.try(&.["message"].as_s) == "Card declined"
    raise "Reservation was not released" unless DemoInventory::RELEASED.get
    puts "PASS failed payment released its reservation"
  end
ensure
  JoobQPro.shutdown
  JoobQ.shutdown
end
```
{% endcode %}

Run `crystal run src/compensated_checkout.cr`. Expect `PASS failed payment released its reservation`. The workflow remains failed even though compensation succeeded.

```mermaid
sequenceDiagram
  participant W as Workflow
  participant I as Inventory
  participant P as Payment
  W->>I: Reserve
  I-->>W: Reservation ID
  W->>P: Charge
  P-->>W: Permanent failure
  W->>I: Release reservation
  W->>W: Finish failed
```

Real compensations need stable business identity, their own external-client timeouts, and a reconciliation path. A refund is not the same operation as deleting a charge. Some effects, such as a sent email, cannot be undone.

The existing engine compensates completed steps in reverse completion order. A compensation failure can leave the workflow with `compensation_incomplete`; compensations do not inherit the original step's retry policy. Monitor that outcome and assign an operator recovery path. Keep long-running activities cancellation-aware so unwinding can progress.

**Next:** [Handle failures](../guides/handle-failures.md).
