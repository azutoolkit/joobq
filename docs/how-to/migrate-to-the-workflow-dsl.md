---
description: Adopt the DSL without silently changing persisted identities or dependency graphs.
---

# Migrate to the workflow DSL

*How-to · Pro · Preview*

## Prerequisites

- Pro 0.2.4 (the DSL is in Pro since v0.2.2) and an existing `Definition.new` / `Step.*` / `register_activity` workflow; those APIs stay supported.

## Steps

1. Write the DSL version, naming each activity with the name it was registered under (the DSL's default is the fully qualified class name), and pass `input: nil` where the old step had no input (an omitted DSL input is the workflow input):

<!-- illustrative: conversion of an existing definition whose activity name is ChargeCard -->
```crystal
Checkout = workflow "checkout", version: 1 do
  activity "ChargeCard", Payments::ChargeCard
  step :charge, "ChargeCard", input: nil
end
```
2. Keep the workflow name, version, step ids, activity names, inputs, deadlines and lifecycle settings; wrap steps that ran independently in `parallel` (the DSL is sequential by default); keep declaration and dependency order.
3. Compare `old_definition.to_json` with `blueprint.definition.to_json`, then compare their `hash_id`.
4. Exercise a run, a retry, a compensation, a restart and a replay against isolated Redis.
5. Deploy workers that register the new blueprint before you admit runs that use new activity names.

## Verify

- The two JSON documents and the two `hash_id` values are equal.
- Runs started before the change complete on their original definition.

## See also

- [Workflow DSL](../reference/workflow-dsl.md)
- [Workflows and sagas](../explanation/durable-workflows.md)
