---
description: Use existing lifecycle capabilities through declarative Crystal helpers.
---

# Lifecycle controls

These helpers build the existing `Definition` fields. They do not add a second execution engine or new replay semantics.

## Scopes and conditions

<!-- illustrative: declarations inside a workflow block with existing activity classes -->
```crystal
parallel do
  scope :optional, timeout: 1.minute do
    wait_for :approval, signal: :approved, timeout: 30.seconds
  end

  sequence do
    step :prepare, PrepareOrder
    step :notify, NotifyCustomer, only_if: input(:notify)
  end
end
```

Scopes annotate their contained steps. They do not change sequential or parallel ordering. Each step belongs to one scope; nested scopes are rejected. `non_cancellable: true` uses the engine's existing cleanup semantics, cannot have a scope timeout, and requires a timeout on a signal wait inside it.

Native Crystal `if` and loops run while the definition is built. Use `only_if:` for runtime decisions. A reference object is not the runtime boolean it describes. Do not put time-dependent or environment-dependent construction logic into a definition you expect to keep identical across builds.

## Changes and version gates

<!-- illustrative: declarations inside a workflow block -->
```crystal
change :pricing, min: 0, max: 1

parallel do
  step :legacy, LegacyPricing, gate: version_gate(:pricing, max: 0)
  step :current, CurrentPricing, gate: version_gate(:pricing, min: 1)
end
```

The engine records version decisions in history. Preserve old paths until affected runs drain, and keep the existing migration/replay review process. Merely publishing a new blueprint does not rewrite an open run's definition.

## Queries and updates

<!-- illustrative: declarations inside a workflow block -->
```crystal
query :payment, output(:charge)

update :amend,
  activity: AmendOrder,
  input: ref("update.input"),
  validate: ref("update.input.order_id"),
  validator: "valid_amendment",
  message: "Order ID is required",
  timeout: 30.seconds
```

Register named application validators through the existing `Updates.validator` API. `update` accepts an optional activity; without one, `result:` supplies the response. `input:` and `result:` both default to `ref("update.input")`. Only update handlers can reference the `update` context root.

Queries and updates can observe state before a referenced step finishes. Unlike activity inputs, their references do not add dependency edges. Handle unavailable values in your application.

## Continue as new

<!-- illustrative: declaration inside a workflow block -->
```crystal
continue_as_new input: input,
  only_if: input(:repeat),
  max_events: 1000,
  max_runs: 10,
  build: JoobQPro::Workflows::BuildPolicy::Pinned
```

The existing engine starts a successor run and preserves its continuation rules. `max_events` must be large enough for the definition; `max_runs` must be positive. `BuildPolicy::Upgrade` selects the existing upgrade-at-run-boundary behavior. These settings do not make activity side effects exactly once.

See the [migration guide](migration.md) before converting a production definition.
