---
description: Tune work in flight without confusing fibers, threads, and connection counts.
---

# Concurrency and shutdown

Start with a small worker count and measure completion latency, queue age, retries, and downstream saturation. A larger pool or more fibers can make an overloaded dependency slower.

| Control | Scope |
| --- | --- |
| Queue worker count | Concurrent workers for a queue in one process |
| Worker batch size | Amount fetched per poll |
| `CRYSTAL_WORKERS` | Runtime threads when compiled with the applicable multithreading flag |
| Redis pool size | Connections available to one configured pool |
| Delivery capacity | Opt-in runtime capacity, separate from legacy queue workers |
| Pro rate limit | Shared admission budget for a named key and time window |

## Try multiple runtime threads

```sh
mkdir -p bin
crystal build src/worker.cr --release -Dpreview_mt -o bin/worker
CRYSTAL_WORKERS=4 ./bin/worker
```

Create `bin/` first if needed. Choose thread count from the CPUs actually allocated to the process, not the host's total. Verify application code and third-party clients under the same runtime mode. Fibers do not make a CPU-bound handler parallel by themselves.

## Give shutdown time to finish

`JoobQ.forge` installs signal handling by default. SIGTERM, SIGINT, and SIGHUP initiate shutdown. The worker stops claiming new work, drains active work within its budget, and attempts to return unfinished work. A forced kill, unavailable Redis, or expired supervisor grace period can prevent that final handoff.

The Core baseline exits with status `3` when shutdown reports abandoned work. Alert on that outcome and investigate retained queue/processing state. A second termination signal can force exit; do not use repeated signals as a normal drain procedure.

If you disable signal trapping, your application owns the lifecycle: call the relevant shutdown methods and inspect the result. For Pro workflows, stop Pro services before Core. Allow a supervisor grace period longer than the complete shutdown budget.

`azu jobs:worker --shutdown-timeout 25` controls the CLI worker's Core drain budget. It does not impose a deadline on every external side effect. Check [CLI management](../pro/management.md) before changing worker-process options.
