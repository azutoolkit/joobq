---
description: How JoobQ works and why it is built this way.
---

# Explanation

Explanation pages give the background behind the tasks: the model, the trade-offs and the limits. Each one shows the idea in a diagram and a small program you can run, and says where JoobQUI fits. The label after each page says which part of JoobQ it covers: Core, Pro or JoobQUI.

## Getting Started

* [Why JoobQ](why-joobq.md) · Core · Pro · JoobQUI
* [Architecture at a glance](application-architecture.md) · Core · Pro · JoobQUI
* [Open Source vs Pro vs JoobQUI](pro-features.md) · Core · Pro · JoobQUI

## Core

* [Jobs and payloads](job-lifecycle.md) · Core
* [Queues and priorities](queues-and-workers.md) · Core
* [Workers and concurrency](workers-and-concurrency.md) · Core
* [Retries, backoff and the DLQ](retries-and-dead-letters.md) · Core
* [Cron and recurring jobs](delayed-and-recurring-jobs.md) · Core · Pro · JoobQUI
* [Rate limiting and throttling](rate-limiting-and-throttling.md) · Core · Pro

## Advanced

* [Workflows and sagas](durable-workflows.md) · Pro
* [Batches and unique jobs](distributed-coordination.md) · Pro · Preview
* [Delivery](delivery.md) · Core · Preview
* [Polyglot SDKs and the gateway](https://joobq-website.onrender.com/docs/explanation/how-workers-run-your-code) · JoobQUI

## Production Ops

* [Live observability and metrics](metrics-and-observability.md) · Core · Pro · JoobQUI
* [Security model](https://joobq-website.onrender.com/docs/explanation/security-audit-and-redaction) · Core · JoobQUI
