---
description: Choose a small, repeatable structure for the work your application needs.
---

# Design Patterns

A pattern is a starting point, not another framework to learn. Choose the smallest one that makes ownership, retries, and recovery clear.

| Pattern | Use it when | Keep in mind |
| --- | --- | --- |
| [Thin jobs](thin-jobs.md) | One background action calls a business service | Keep queue setup out of business code |
| [Fan-out and join](fan-out-and-join.md) | Independent steps can overlap | Parallelism still consumes worker and downstream capacity |
| [Sagas](sagas.md) | Later failures need to undo earlier effects | Compensation is another fallible operation |
| [Transactional outbox](transactional-outbox.md) | A database change must eventually enqueue work | Dispatch can repeat after a lost acknowledgment |

Pair every pattern with [idempotent effects](../best-practices/idempotency.md). Leases, unique admission, and retries help coordinate work; none makes a remote payment or email exactly once.

For the wider application structure, see [Application architecture](../best-practices/architecture.md). For API details, keep the [DSL reference](../pro/workflow-dsl/reference.md) nearby.
