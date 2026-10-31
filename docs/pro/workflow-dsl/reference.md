---
description: The complete preview authoring surface, with explicit ordering and data references.
---

# Workflow DSL reference

**Available since Pro v0.2.2; authoring API preview.** See [availability](README.md). Import `JoobQPro::Workflows::DSL` where you declare workflows.

## Workflows, catalogs, and activities

| Declaration | Behavior |
| --- | --- |
| `workflow "name", version: 1, timeout: 1.minute do … end` | Returns a validated `Blueprint`; timeout is optional |
| `workflows do … end` | Groups `workflow` declarations into a `Catalog` |
| `activity :billing, ChargeCard` | Binds an explicit persisted activity alias; does not execute a step |
| `step :charge, ChargeCard` | Executes a typed activity using its fully qualified class name |
| `step :charge, :billing` | Executes the activity declared under that alias |
| `parallel do … end` | Concurrent branches starting from the current dependency frontier |
| `sequence do … end` | Ordered steps, particularly useful inside a parallel branch |

A catalog requires unique workflow names and consistent activity bindings. `Worker#register` accepts a blueprint or catalog. `Client#register` publishes definitions only. Catalog validation happens before publication, but publication across several definitions is not a Redis transaction: inspect and retry registration if a connection fails midway.

Activity classes need one unambiguous `perform(input : InputType, context : JoobQPro::Workflows::ActivityContext)`, a constructor callable without arguments, JSON-deserializable input, and JSON-serializable output. Named input types resolve in the activity's namespace. Qualify generic input arguments when their types live in another namespace. Construction and execution happen only when the worker invokes the handler.

There is no inline `task` body or new `task` alias. Keep business logic in testable Crystal activities.

## Order and parallel branches

In this fragment, the activity classes belong to your application:

<!-- illustrative: application-defined activities with compatible input and output types -->
```crystal
Checkout = workflow "checkout", timeout: 15.minutes do
  step :reserve, ReserveInventory

  parallel do
    step :receipt, SendReceipt, input: output(:reserve)

    sequence do
      step :pack, PackOrder
      step :ship, ShipOrder, input: output(:pack)
    end
  end

  step :complete, CompleteOrder
end
```

`receipt` and `pack` wait for `reserve`. `ship` waits for `pack`; `complete` waits for both `receipt` and `ship`. No synthetic activities are inserted. `after:` adds dependencies without removing these ordering rules. A skipped conditional step follows the existing engine's completion rules; consumers must handle unavailable output.

## Step options

| Option | Meaning and default |
| --- | --- |
| `input:` | Original workflow input by default; explicit `nil` remains JSON null |
| `after: [:other]` | Adds dependencies to the implicit sequential dependencies |
| `retry:` | `retry_policy`; one attempt by default |
| `compensate:` | `compensation(ActivityClass, input: …)` or a declared activity alias |
| `only_if:` | Reference or existing expression string, evaluated with engine truthiness |
| `timeout:` | Optional activity start-to-close duration; omitted preserves engine defaults |
| `heartbeat:` | Optional heartbeat duration; activity code calls `context.heartbeat` |
| `schedule_to_start:` | Queue-wait redispatch interval; defaults to 5 minutes, not a terminal failure deadline |
| `gate:` | `version_gate(:change, min: …, max: …)` |

`retry_policy(attempts: 3, initial: 1.second, backoff: 2.0, maximum: 1.minute, non_retryable: ["FatalError"])` describes activity attempts, including the first. Delays must be positive; backoff must be finite and at least one.

When `schedule_to_start:` elapses while the step is still scheduled, the reconciler redispatches the same attempt and rearms the deadline. If its pinned build has no live workers, it rearms without sending another copy. Use a workflow timeout to bound the overall run; unwinding and compensation can continue beyond that timeout. The default activity start-to-close timeout is ten minutes, and heartbeats are disabled unless configured.

All duration helpers require positive whole milliseconds within `Int64` range. Sub-millisecond values are rejected rather than rounded into zero. Supplying a duration does not make an external side effect cancellable.

## Inputs and outputs

| Helper | Persisted expression |
| --- | --- |
| `input` | `${input}` |
| `input(:order_id)` | `${input.order_id}` |
| `output(:charge)` | `${steps.charge.output}` |
| `output(:charge, :receipt_id)` | `${steps.charge.output.receipt_id}` |
| `ref("input.customer.email")` | `${input.customer.email}` |

References work inside named tuples, arrays, and hashes. They are descriptions, not values fetched during construction. Unknown step references and reads from unfinished parallel siblings fail validation; use `after:` or move the consumer after the parallel block. Compensation may reference its own completed step's output.

The DSL checks graph dependencies, not arbitrary JSON field shapes. Missing fields retain the engine's null semantics; typed activity deserialization can reject an incompatible input at execution time. Existing `${…}` string interpretation is unchanged.

## Other executable steps

- `wait_for :approval, signal: :approved, timeout: 1.day`: consumes a signal through the existing engine.
- `timer :cooldown, for: 5.minutes`: creates a durable timer rather than sleeping during definition construction.
- `child :shipping, workflow: :fulfillment, input: input`: starts a registered child workflow.

These steps accept `after:`, `only_if:`, `gate:`, and `compensate:`. Signal wait supports `timeout:`. Child declarations accept the underlying definition's retry, compensation, and timeout fields for serialization compatibility; the current engine retries activities only and does not turn a child timeout field into a new execution deadline. Use existing child/workflow lifecycle controls for those semantics.

For queries, scopes, updates, version changes, and continuation, see [lifecycle controls](lifecycle.md).
