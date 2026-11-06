---
description: Adopt the DSL without silently changing persisted identities or dependency graphs.
---

# Migrate a constructor-based definition

Upgrade to **JoobQ Pro v0.2.2** before adopting the DSL. Keep existing `Definition.new`, `Step.*`, and `register_activity` code working while you migrate; none of those constructor APIs is deprecated. The DSL authoring API remains a preview.

## Preserve identity first

The DSL's implicit activity name is its fully qualified Crystal class name. Existing `register_activity` calls commonly use the final class-name segment or an explicit alias. Declare that existing name deliberately:

<!-- illustrative: conversion of an existing definition whose activity name is ChargeCard -->
```crystal
Checkout = workflow "checkout", version: 1 do
  activity "ChargeCard", Payments::ChargeCard
  step :charge, "ChargeCard", input: nil
end
```

Explicit `nil` matters: the old constructor defaults to null input, while an omitted DSL activity input uses `${input}`. Matching step IDs and workflow names alone is not enough for hash equality.

## Compare the complete graph

1. Preserve workflow name, version, step IDs, activity aliases, inputs, deadlines, and lifecycle settings.
2. Translate independent steps into `parallel`; the DSL is sequential by default.
3. Preserve declaration and dependency-array order when exact JSON/hash equivalence is required.
4. Compare `old_definition.to_json` with `blueprint.definition.to_json`, then compare `hash_id`.
5. Exercise representative executions, retry and compensation paths, restart recovery, and replay before rollout.

When values and ordering match, the serialized definition and hash match. A deliberate graph change produces a different hash. Existing runs remain pinned to their original definition unless you invoke the engine's explicit migration APIs.

## Registration and deployment

`Worker#register(blueprint)` installs activity bindings and publishes definitions. Repeated registration of the same typed binding is idempotent. A different implementation using the same name is rejected; select a distinct alias and deployment strategy rather than silently replacing it.

`Client#register(blueprint)` publishes only the definition. Deploy compatible workers before admitting work that uses new activity names. Build pinning remains the existing engine's responsibility.

Blueprints return detached definitions so inspection cannot mutate their validated contents. Catalog publication is not atomic across workflows. Following a connection error, reconcile published definitions before assuming a complete rollout.

The DSL allocates builders and serializes data during authoring/registration. The activity runner, Redis history format, dispatch path, and handler argument serialization remain the existing execution path; this release makes no throughput improvement claim.
