---
title: Architecture & Deployment Models
description: How JoobQ, JoobQ Pro and JoobQUI fit together, what lives in Redis and PostgreSQL, and the ways to run them.
order: 1
---

## Three layers on one Redis

```text
 your app ──enqueue / start──▶  Redis  ◀──claim / append──  JoobQ workers (+ Pro workflow workers)
                                  ▲
                                  │ read, operate, live events
                              JoobQUI web ── PostgreSQL (accounts, tokens, audit, channels)
```

- **JoobQ** is a library inside your Crystal processes. Producers write jobs to Redis lists; workers in the same or other processes claim them with fibers, run `perform`, and record retries, dead letters, counters and lifecycle events. There is no JoobQ server to run.
- **JoobQ Pro** adds a workflow engine in the same processes. Orchestrators decide what happens next from a run's history; activities travel as ordinary JoobQ jobs on `wf_activities` queues. JoobQ is only the transport: the history is the truth.
- **JoobQUI** is an Azu web application that reads and operates the same Redis, keeps its own records in PostgreSQL, and serves the console as static files under `/ui/`.

## What lives where

| Store | Holds | If you lose it |
| --- | --- | --- |
| Redis | Queues, processing lists, delayed and dead-letter sets, workflow histories and indexes, the `joobq:events` stream, pause flags and desired concurrency, console sessions and rate limits, leader leases | Work in flight and unarchived history. Run it with persistence (AOF) and back it up |
| PostgreSQL | Console accounts, API token hashes, audit log, notification channels, migrations | Access and audit records; jobs keep running |
| Workflow archive (optional) | Closed runs exported before retention deletes them | Only the exported copies |

Redis Cluster is not supported (keys are not hash-tagged). Pause state and concurrency are stored in Redis (`joobq:queue:<name>:paused`, `…:config`), so they hold for every worker and survive restarts; workers apply a new concurrency at their next heartbeat, within 10 seconds.

## Processes

| Process | Runs | Scale |
| --- | --- | --- |
| Your producers | `enqueue`, `client.start`, `signal` | Any number |
| JoobQ workers | `JoobQ.forge`: queues, schedulers, the optional management API | Any number per queue |
| Pro workflow workers | `Worker.new.register(...).start`: activities, orchestrators, the workflow scheduler | Any number; one scheduler leader by lease |
| JoobQUI web | Console, `/api/v1`, `/metrics` | Any number behind a load balancer; alerts and retention run on the lease holder |
| JoobQUI worker | `joobqui-selfhosted --worker`: JoobQ queues and YAML `schedulers:` | As your queues need |

Stopping is ordered: `JoobQPro.shutdown` first (resign the scheduler lease, stop dispatching), then `JoobQ.shutdown` (stop claiming, wait for running jobs, put back what outlives the deadline).

## Deployment models

- **Library only.** JoobQ (and Pro) inside your services, Redis next to them. Inspect with the Azu CLI (`azu jobs:status`, `azu joobq`) or the management API.
- **Self-hosted console.** `joobqui-selfhosted` in your network, licensed with a `jq_lic_…` key that checks in with the license service every 15 minutes. Job data and accounts never leave your infrastructure; the check-in carries the origin, the active account count and the version.
- **Operations agent.** The same `/api/v1` behind an agent gate, without browser sign-in or the static console, for environments a central console reaches through a private agent.

## Delivery guarantees

Delivery is at least once. A job can run again after a crash, a redelivery, or a shutdown that put it back; a workflow attempt starts at most once, but its activity can run again after a Redis restart or a worker crash. Use idempotency keys (`ctx.dedupe_key` for activities) at external boundaries. Durability is Redis's: with `appendfsync always` an acknowledged history append survives a crash.
