---
description: Add coordination and visibility without replacing the concepts you already know.
---

<!-- diataxis: split in explanation PR -->

# Pro Features

JoobQ Pro builds on the Core runtime. The upgrade adds workflow orchestration, metrics and alerting, plus explicit coordination services. It does not make persistence configuration, graceful shutdown, or idempotency somebody else's responsibility.

| Capability | Guide | Important boundary |
| --- | --- | --- |
| Typed workflows, dependencies, signals, timers, children, compensation | [Workflow DSL](../tutorials/parallel-workflow-dsl.md) | Available since Pro v0.2.2; authoring preview; effects can repeat |
| Durable batches, uniqueness, and distributed rate limits | [Coordination](distributed-coordination.md) | Durable services require an explicit Delivery runtime |
| Metrics, percentiles, alerts, and structured logs | [Observability](metrics-and-observability.md) | Configure collection and external export deliberately |
| Queue, workflow, and DLQ inspection | [CLI management](../reference/azu-cli-and-terminal.md) | CLI inspection is shared with Core; Pro adds workflow data |

Start with [adding Pro](../how-to/add-pro.md), then run [one activity](../tutorials/first-pro-workflow.md). Each guide identifies the API family it uses so you can keep ordinary jobs running while adopting one Pro capability at a time.

[Screenshot: The JoobQ terminal workflow view showing a process-order run with dependent steps, current attempts, a waiting signal, and a separate queue/worker pane.]
