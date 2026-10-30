---
description: Measure completed work, tail latency, and recovery on your own workload.
---

# Performance testing

Crystal and Redis can sustain high throughput, but a no-op benchmark does not predict mail delivery, payment calls, or SQL-heavy jobs. This documentation does not promise a universal jobs-per-second number.

## Record a reproducible test

Capture the source revision and lockfile, Crystal version and flags, allocated CPU/RAM, Redis version and persistence, network latency, job payload size, handler work, worker count, batch size, pool sizes, and run duration.

Report completed jobs per second, p50/p95/p99 completion latency, oldest queued age, errors/retries, CPU, RSS, GC pressure, and Redis connection/command latency. Distinguish accepted admissions from completed jobs and retained metric windows from lifetime totals.

## Tune one constraint at a time

1. Establish a single-process baseline with representative handlers.
2. Increase queue workers until throughput stops improving or downstream latency rises.
3. Test multiple Crystal runtime threads with the same build flags used in production.
4. Adjust batching and pools while watching fairness, connection limits, and queue age.
5. Run a sustained workload, then repeat with worker termination and Redis disruption.
6. Verify counts and business effects after recovery, not only during the fastest interval.

Batching reduces command overhead but can increase the amount of work held by one worker. More parallelism can exhaust database or HTTP pools. Optimize the measured bottleneck while retaining idempotency and recovery checks.

[Screenshot: A benchmark report showing source revision, allocated CPUs, completed jobs per second, p99 completion latency, error count, and memory trend, with no unsupported headline throughput claim.]
