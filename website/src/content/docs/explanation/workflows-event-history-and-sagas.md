---
title: Workflows, Event History & Sagas
description: Why a JoobQ Pro workflow is a fold of its history, how decisions stay deterministic, and how compensation unwinds a saga.
order: 2
product: pro
---

## A workflow is data plus a history

A definition is a declared graph of steps: activities, signal waits, timers and child workflows, with dependencies, retry policies, timeouts and compensations. It is data, stored by hash, so any process can decide what happens next.

A run is an append-only **history** of events in Redis: `WorkflowStarted`, `StepScheduled`, `StepStarted`, `StepCompleted`, `StepFailed`, `StepRetrying`, `SignalReceived`, `TimerFired`, `CompensationStarted`, `WorkflowCompleted` and so on. The run's state is always the fold of that history. Nothing else is the truth: queues, indexes and live announcements are derived from it and can be rebuilt.

## Appends are atomic and conditional

Appending an event and its effects (dispatching the next activity, arming a timer or a deadline) is one Lua script. Every append is conditional on the history it was decided from, so two orchestrators, or a stale one, cannot both win. Signals are the exception: they are appended blind, so senders never conflict. A short lease only avoids duplicate work; correctness does not depend on it. Timers and deadlines are leased rather than removed, so a crash does not lose them.

This is why a worker can die at any point: another one reads the history and carries on from the last event Redis kept.

## Attempts start at most once, activities may repeat

Only the currently scheduled attempt of a step may start or finish it. A job that is never picked up is re-sent after `schedule_to_start_ms` (5 minutes by default); an attempt that starts and never reports back fails after its `timeout_ms` (10 minutes by default) and is retried by its `RetryPolicy`. After a Redis restart or a worker crash an activity can therefore run again, which is why `ActivityContext#dedupe_key` exists: pass it to the service you call.

## Replay keeps changes honest

Because decisions are a function of the definition and the history, `replay(history, definition)` can re-run the engine's decisions against new code and compare them with what was recorded. Engine events must match; outside events (signals, activity results, timers, operator commands) are applied as recorded. The result is `ok?` or a `divergence` naming the event, its position and the reason, without payloads. `migrate` uses this: it moves an open run onto new code only if the new code agrees with every decision so far. Declared changes (`change` plus `version_gate`) let old and new paths coexist; worker build ids keep activity code for open runs on the build they started with.

## Sagas: undo what was done, newest first

Give a step a `compensate:` activity and the workflow becomes a saga. When it fails, is cancelled or times out:

1. Activities still executing are waited for, so their work can be undone too.
2. Completed steps with a compensation are undone one at a time, newest first.
3. A compensation that fails or times out ends the workflow `failed` with `compensation_incomplete`; compensations are not retried.

Cancelling compensates; terminating does not. Children follow their parent: a terminated parent terminates its running children, a cancelled, failed or timed-out parent cancels them so they undo their own work.

**Scopes** apply the same idea to part of a run: cancel a scope and its unstarted steps are cancelled, its completed steps compensated, while the rest of the workflow continues. A `non_cancellable` scope holds cleanup that still runs when the workflow unwinds.

## Keeping histories bounded

Histories grow with every event. A long-lived workflow declares `continue_as_new` (for example on `max_events`): the run closes as `continued_as_new` and a fresh run of the same workflow starts with the carried input and any unconsumed signals; ids are `<root>--r<n>` and signals and results follow the chain. Closed runs stay in Redis until `prune` or `retire` deletes them, optionally after exporting them to an archive.

## Limits worth knowing

- One Redis, no Cluster. Use AOF `appendfsync always` if losing the last second of history is not acceptable.
- Live announcements (`history.appended`, `workflow.updated` on `joobq:events`) are best effort; consumers resync from the history when they see a gap.
- Search attributes are set at start, by the client or from activities, not by a step declaration.
