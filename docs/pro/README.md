---
description: Add coordination and visibility without replacing the concepts you already know.
---

# Pro Features

JoobQ Pro builds on the Core runtime. The upgrade adds workflow orchestration, metrics and alerting, plus explicit coordination services. It does not make persistence configuration, graceful shutdown, or idempotency somebody else's responsibility.

| Capability | Guide | Important boundary |
| --- | --- | --- |
| Typed workflows, dependencies, signals, timers, children, compensation | [Workflow DSL](workflow-dsl/README.md) | Available since Pro v0.2.2; authoring preview; effects can repeat |
| Durable batches, uniqueness, and distributed rate limits | [Coordination](coordination.md) | Durable services require an explicit Delivery runtime |
| Metrics, percentiles, alerts, and structured logs | [Observability](observability.md) | Configure collection and external export deliberately |
| Queue, workflow, and DLQ inspection | [CLI management](management.md) | CLI inspection is shared with Core; Pro adds workflow data |

Start with [adding Pro](../introduction/adding-pro.md), then run [one activity](../quick-start/first-workflow.md). Each guide identifies the API family it uses so you can keep ordinary jobs running while adopting one Pro capability at a time.

[Screenshot: The JoobQ terminal workflow view showing a process-order run with dependent steps, current attempts, a waiting signal, and a separate queue/worker pane.]
