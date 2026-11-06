---
description: Measure completed work, tail latency, and recovery on your own workload.
---

# Measure performance

*How-to · Core*

## Prerequisites

- A test environment shaped like production (CPU, memory, Redis version and persistence, network), and a representative job, not a no-op.

## Steps

1. Record the conditions: source revision and `shard.lock`, Crystal version and flags, allocated CPU and memory, Redis version and persistence, payload size, worker count, `worker_batch_size` and pool sizes.
2. Run one process with a fixed worker count and record completed jobs per second, p50/p95/p99 completion time, oldest waiting age, errors and retries, CPU and RSS.
3. Raise the worker count step by step until completions stop rising or downstream latency rises; change one setting at a time.
4. Repeat with the multithreaded build and `CRYSTAL_WORKERS` set to the CPUs allocated to the process.
5. Run the best setting for a sustained period, then again while stopping a worker and restarting Redis, and check every job's effect afterwards.
6. To compare with the committed Core measurement, run `benchmarks/legacy.cr` from the joobq repository: `crystal build benchmarks/legacy.cr --release -o /tmp/joobq-legacy`, then `CRYSTAL_WORKERS=4 BENCH_JOBS=30000 BENCH_MODE=worker python3 scripts/run_integration.py --probe /tmp/joobq-legacy`.

## Verify

You have a table of completed jobs per second and p99 completion time per setting, with the conditions of step 1 written next to it.

## See also

- [Why JoobQ](../explanation/why-joobq.md): the committed measurement and its conditions.
- [Workers and concurrency](../explanation/workers-and-concurrency.md)
