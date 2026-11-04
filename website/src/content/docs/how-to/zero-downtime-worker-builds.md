---
title: Zero-Downtime Worker Builds
description: Ship new activity code while in-flight runs finish on the build they started with, then retire the old build.
order: 3
product: pro
---

Worker build ids let two versions of your activity code run side by side. A run is pinned to a build when it starts, and only workers of that build run its activities, so in-flight runs finish on the code they started with while new runs go to the new build.

> Upgrade every process first. Code from before build ids cannot read the `BuildPinned` event. Finish rolling out a JoobQ Pro version with build ids to every worker, orchestrator and console before the first `promote` or `repin`.

## 1. Name the build each process carries

Set `JOOBQ_PRO_BUILD_ID` in the environment of each worker (it is the default for `build_id:`), or pass it in code:

```crystal
worker = JoobQPro::Workflows::Worker.new(store, build_id: "2026-11-04.1")
worker.register(OrderFulfilment).start
```

A build belongs to a **compatibility set**: builds whose workers may run each other's runs. A new id starts its own set; `compatible_with: "2026-10-20.3"` joins an older build's set (use it for a fix that can carry the old runs' histories). Build ids match `[A-Za-z0-9_.-]{1,64}`.

## 2. Deploy the new workers next to the old ones

Keep the old workers running. Registering a build never sends runs to it. Check both sets are alive:

```crystal
client.build_ids("order-fulfilment")
# => BuildInfo per set: builds, default_for, pinned (open runs), workers, backlog, stalled?
```

In JoobQUI the **Workflow builds** page shows the same (`GET /api/v1/workflow-builds`).

## 3. Promote the new build

```crystal
client.promote_build("order-fulfilment", "2026-11-04.1")   # "*" = every workflow without its own default
```

From now on new runs of `order-fulfilment` are pinned to the new set. Runs already open stay where they are. Promote, retire and re-pin are **admin** actions in the console, because they move work.

## 4. Drain and retire the old build

```crystal
client.pinned_counts         # => {"2026-10-20.3" => 12}; wait for 0
client.retire_build("2026-10-20.3")
```

`retire_build` is refused (`BuildInUse`) while runs are pinned to the set or it is still a workflow's default. Stop the old workers after it succeeds. Retiring cannot be undone.

If you cannot wait, move runs explicitly. Re-pinning is your statement that the target build can carry the run's history; the engine does not check it, so replay first:

```crystal
client.repin(id, "2026-11-04.1")                       # one run (cascade: true includes children)
client.repin_pinned("2026-10-20.3", "2026-11-04.1")    # everything pinned to a build
```

## What happens when no worker of a build is alive

The run waits: its activities stay queued for that build, are re-sent every `schedule_to_start_ms`, and are never run by another build. `client.query(id, "build")` answers `{pinned, set, build, workers, backlog, waiting}`. Compensations are the exception: when no worker of the pinned build is alive they go to the shared queue, so cancellation and timeouts can still undo completed steps.

## Long-running chains

`continue_as_new` keeps the chain's build by default (`BuildPolicy::Pinned`). Declare `continue_as_new build: BuildPolicy::Upgrade` to move each new run of the chain to the current default build.

Build ids are for activity code. A change to a definition's steps needs a declared change and `migrate`; see [Operate workflows in production](/docs/how-to/operate-workflows-in-production).
