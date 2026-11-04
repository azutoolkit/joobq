---
title: Operate Workflows in Production
description: Find runs, act on one or many, change code safely with replay and migration, and keep history bounded.
order: 2
product: pro
---

## Run enough of the right processes

- **Workers** (`JoobQPro::Workflows::Worker`) run activities (`activity_workers`, default 10 fibers) and orchestrators (`orchestrators`, default 2) that decide what happens next. Register every definition in every worker process.
- **One scheduler leader.** Every worker runs the workflow-schedule loop unless built with `scheduler: false`; a Redis lease makes one process the leader. `Scheduler.leader_status(store)` says whether a leader is alive.
- **Stop in order.** On shutdown call `JoobQPro.shutdown` before `JoobQ.shutdown`, so the scheduler lease is resigned and activities stop being dispatched before the queues drain.
- **Redis.** One server (no Cluster); AOF with `appendfsync always` if losing the last second of history is not acceptable.

## Find a run

```crystal
client = worker.client
client.describe(id)                 # State: status, steps, signals, search attributes
client.history(id, after_seq: 0)    # events, 200 per page
client.list(JoobQPro::Workflows::WorkflowStatus::Failed, limit: 20)
client.search(JoobQPro::Workflows::Filter.new.prefix("customer", "ac").range("total", min: 100))
```

In JoobQUI the **Workflows** page lists runs by status and name, searches by id, and filters by search attributes (`GET /api/v1/workflows?eq=customer:acme&range=total:100..`). A run's page draws its graph and its full history; scrub back to see the state at any event.

## Act on one run

| Action | Crystal | Console / API | Effect |
| --- | --- | --- | --- |
| Signal | `client.signal(id, "approve", payload)` | `POST /workflows/:id/signal` | Feeds a `wait_for` step |
| Query | `client.query(id, "progress")` | `POST /workflows/:id/query` | Reads state, changes nothing |
| Update | `client.update(id, "set_address", input, update_id:)` | `POST /workflows/:id/updates/:name` | Validated request with an answer, recorded in history |
| Cancel | `client.cancel(id, reason)` | `POST /workflows/:id/cancel` | Unwinds: compensations run newest first |
| Terminate | `client.terminate(id, reason)` | `POST /workflows/:id/terminate` | Stops now; nothing is undone |
| Retry a step | `client.retry_step(id, step)` | `POST /workflows/:id/steps/:step/retry` | Re-runs a failed activity |
| Re-drive | | `POST /workflows/:id/redrive` | New run `<id>-redrive`, same input |

Commands answer `409` when they no longer apply (the run already finished), never a silent success. Cancel and terminate reach child workflows.

## Act on many runs

`POST /api/v1/workflows/bulk` (operator) terminates, cancels, signals or re-drives up to 200 runs named by `ids`, or up to 500 selected by `status`, `name` or `search` with `all_matching: true`. Send `dry_run: true` first: it returns the matched ids and changes nothing. The whole call is one audit event (`workflow.bulk_<action>`).

## Change code without breaking open runs

A run is pinned to the definition hash it started with. To change the steps of a running workflow:

1. Gate old and new paths with a declared change (`change "fraud", min: 0, max: 1` and `version_gate(...)` on steps).
2. Replay first: `client.replay(id, new_definition)` re-decides the recorded history against the new code and returns `ok?` or the first `divergence`.
3. Move the run: `client.migrate(id, new_definition)` replays and appends `DefinitionChanged` only if the new code agrees with every decision so far. In the console, migrate takes `dry_run: true`; `force` needs an admin.

Activity code changes (same steps, new implementation) go through [worker build ids](/docs/how-to/zero-downtime-worker-builds).

## Keep history bounded

- `continue_as_new max_events: ...` closes a long-running run as `continued_as_new` and starts a fresh one; unconsumed signals travel with it.
- Nothing prunes by itself: call `client.prune(before)` from a job, or set `JOOBQUI_WORKFLOW_RETENTION_DAYS` in the console. Pair it with an archive (`JOOBQUI_WORKFLOW_ARCHIVE_DIR`, or `FileArchive` in code) to export closed runs before deletion; open runs are never deleted.
- Watch `joobqui_workflows{status="failed"}` and `joobqui_workflow_archive_failures` on [`/metrics`](/docs/reference/rest-api-webhooks-and-metrics).
