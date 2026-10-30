---
description: Know what each metric measures before using it to make an operational decision.
---

# Metrics, percentiles, alerts, and logs

Core provides worker/queue state, events, and structured logging. Pro adds metrics collection, percentile tracking, and alert evaluation. A dashboard is useful only when you know its source, freshness, and aggregation window.

## Enable collection deliberately

Load Pro, add `JoobQPro::Middleware::Metrics.instance` to the configured middleware chain, and stop it through `JoobQPro.shutdown`. Preserve the normal retry/timeout middleware; replacing the whole array with only metrics changes job behavior.

<!-- illustrative: insertion into an application that already requires joobq_pro -->
```crystal
JoobQ.configure do |config|
  config.middlewares.unshift(JoobQPro::Middleware::Metrics.instance)
end
```

Configure legacy queues using the registration path for your [installed Core revision](../introduction/compatibility.md#release-specific-integration-notes). Registry heartbeats require an explicit owner in the worker entry point; `forge` does not start that publisher in these baselines.

Position collection according to the outcome you intend to measure. Middleware that catches an exception can affect whether an outer observer sees that exception. Validate success, retry, and terminal failure counters with known jobs rather than inferring their meaning from a label.

The [observability fixture](../../examples/docs/pro/observability.cr) runs a successful job, checks its completion and busy counters, collects metrics, and stops the background loops.

## Read metrics together

| Signal | Useful question | Interpretation limit |
| --- | --- | --- |
| Queue depth and oldest waiting age | Is work accumulating? | Zero depth does not prove workers are alive |
| Fresh worker heartbeats | Are workers reporting? | Redis connectivity is a separate signal |
| Completed jobs per interval | Is useful work finishing? | Enqueues and claims are not completions |
| Execution and wait percentiles | Where is time spent? | State the sample window and units |
| Retry/DLQ counts | Is failure persistent? | Retries can inflate attempt counts |
| Pool wait and Redis errors | Is infrastructure limiting work? | An unknown mutation outcome needs reconciliation |

## Structured logging and export

Core's `JoobQ::JSONLogFormatter` supports structured log records. Keep job ID, worker ID, queue, duration, and a correlation ID; avoid credentials and payload bodies. Use your log collector to send those records to your observability backend.

Do not assume an OpenTelemetry exporter, Prometheus scrape endpoint, or Datadog integration exists because metrics are available internally. Wire a supported adapter or an application-owned exporter, and document its labels, cardinality limits, and failure behavior. Transport failures should not leak job payloads into diagnostics.

[Screenshot: A Pro-enabled queue view showing completed-job rate, queue wait and execution percentiles with units and sample window, worker heartbeat freshness, and an alert alongside the affected queue.]

**Next:** [Capacity planning](../best-practices/performance.md).
