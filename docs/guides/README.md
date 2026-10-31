---
description: Practical walkthroughs for building, testing, and recovering background work.
---

# Guides

Pick the task you want to finish. Each guide names its dependency baseline, explains the outcome, and links to the API details when you need them.

| I want to… | Start here |
| --- | --- |
| Run a background job | [Core quick start](../quick-start/README.md) |
| Build a typed workflow | [Pro DSL quick start](../quick-start/first-workflow.md) |
| Pause work for a human decision | [Wait for approval](wait-for-approval.md) |
| Recover a failed job or workflow | [Handle failures](handle-failures.md) |
| Check behavior before deployment | [Test workflows](test-workflows.md) |
| Choose an application structure | [Design Patterns](../design-patterns/README.md) |
| Run workers outside development | [Production Deployment](../production-deployment/README.md) |

Core examples use the documented Core release; workflow examples use **Pro v0.2.2**. Install the [matching dependency graph](../introduction/compatibility.md) first. A workflow's activity code is ordinary Crystal, while its ordering and lifecycle are stored as a graph.

{% hint style="info" %}
The DSL authoring API is a preview included in Pro v0.2.2. Examples labeled runnable are checked against that release. Application-specific fragments are labeled separately.
{% endhint %}
