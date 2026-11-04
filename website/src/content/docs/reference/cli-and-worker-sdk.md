---
title: CLI & Worker SDK
description: The joobqui-selfhosted commands, and the Crystal APIs for jobs (JoobQ) and workflows (JoobQ Pro).
order: 1
---

## `joobqui-selfhosted`

Run without arguments it starts the web server. Any first argument shaped like `task:name` is a task, and an unknown one is refused (exit 1) instead of starting the server.

| Command | What it does |
| --- | --- |
| *(none)* | Web server: `/ui/`, `/api/v1`, `/metrics` on `HOST:PORT` (default `0.0.0.0:4000`) |
| `--worker` | JoobQ queue workers and the YAML `schedulers:` runner; serves no HTTP |
| `migrate` | Apply the database migrations and exit |
| `doctor` | JSON health report (`database`, `redis`, `session`, `license`); exit 1 if degraded |
| `version` | JSON with the version, Crystal version and mode |
| `accounts:create EMAIL USERNAME [--role ROLE]` | Create an account. Password from `JOOBQUI_ACCOUNT_PASSWORD`, or asked twice. First account is admin, later ones operator |
| `accounts:role EMAIL ROLE` | Change a role (`viewer`, `operator`, `admin`); ends the account's sessions |
| `accounts:erase EMAIL --yes` | Erase an account for good (refused for the last active admin) |
| `accounts:mfa:reset EMAIL` | Remove two-factor authentication; ends sessions and revokes the account's tokens |
| `invites:create [DAYS] [--role ROLE]` | One-use sign-up code, 1 to 365 days (default 7), role default `viewer` |
| `license:status` | Tier, seat usage and expiry of the active license |
| `license:refresh` | Check in with the license service now and store the renewed key |

Tasks are audited with the actor `cli:<operating system user>`.

## JoobQ core (`require "joobq"`)

**Jobs** include `JoobQ::Job` and implement `perform`. Instance variables `@queue`, `@retries` and `@expires` override the configured defaults.

| Call | Effect |
| --- | --- |
| `MyJob.enqueue(**args)` | Store one job in its queue |
| `MyJob.batch_enqueue(jobs, batch_size = 1000)` | Store many at once |
| `MyJob.delay(for: span, **args)` / `MyJob.enqueue_at(span, **args)` | Eligible after `span` |
| `MyJob.schedule(every: span, **args)` | Recurring, process-local |
| `MyJob.perform(**args)` / `MyJob.new(**args).perform` | Run now, in this fiber |
| `encrypted_property name : Type = default` | Seal this field at rest (AES-256-GCM) |

Statuses: `Enqueued`, `Scheduled`, `Running`, `Completed`, `Retrying`, `Dead`, `Expired`, each with `running?` / `running!` style helpers.

**Configuration and lifecycle**

```crystal
JoobQ.configure do |config|
  config.retries = 5
  queue "orders", 10, ProcessOrderJob, throttle: {limit: 100, period: 1.minute}
  scheduler do
    cron("*/5 * * * *") { ReportJob.enqueue }
    every 1.hour, CleanupJob
  end
end

JoobQ.forge(trap_signals: true, shutdown_timeout: 15.seconds)
JoobQ.shutdown(15.seconds)   # true for the call that did the work
JoobQ.abandoned_jobs         # jobs put back at the deadline
```

`JoobQ::DeadLetterQueue.new` gives `page(offset, limit, queue:)`, `find(jid)`, `redrive(jids)`, `redrive_reviewed(jid, digest)`, `purge(jids)` and `purge_all(queue)`.

## JoobQ Pro workflows (`require "joobq_pro"`)

**DSL** (`include JoobQPro::Workflows::DSL`):

| Builder | Declares |
| --- | --- |
| `workflow name, version: 1, timeout: span do … end` | A validated `Blueprint` |
| `step id, ActivityClass, input:, retry:, compensate:, only_if:, timeout:, heartbeat:, schedule_to_start:` | An activity step |
| `wait_for id, signal:, timeout:` | Wait for a signal |
| `timer id, for: span` | Wait for a duration |
| `child id, "workflow-name", input:` | Run a child workflow |
| `parallel do … end`, `sequence do … end` | Branches and ordered groups |
| `scope id, timeout:, non_cancellable: do … end` | A cancellation scope |
| `query name, ref("steps")` | A read-only query |
| `update name, activity:, validate:, timeout:` | A validated update handler |
| `continue_as_new max_events:, max_runs:, build:` | Roll the run into a new one |
| `change id, min:, max:` / `version_gate(change, min:, max:)` | Versioned paths |
| `input(:field)`, `output(:step)`, `ref(path)`, `retry_policy(attempts:, initial:)`, `compensation(Activity)` | Values |

An activity is a class with `perform(input, ctx : ActivityContext)`; `ctx.attempt`, `ctx.dedupe_key`, `ctx.cancel_requested?` and `ctx.upsert_search_attributes(...)` are available.

**Worker**: `Worker.new(store = Store.new, activity_workers: 10, orchestrators: 2, scheduler: true, build_id: ENV["JOOBQ_PRO_BUILD_ID"]?, compatible_with: nil, archive: nil)`, then `register(blueprint)`, `start`, `stop(timeout)`, `client`, `schedules`. `JoobQPro.shutdown(timeout)` stops every worker; call it before `JoobQ.shutdown`.

**Client**

| Method | Purpose |
| --- | --- |
| `start(name, input, id:, search_attributes:, build:)` / `try_start` | Start a run (reusing an id is a no-op) |
| `signal`, `query`, `update(id, name, input, update_id:, timeout:)` | Talk to a run |
| `describe`, `history(id, after_seq:, limit:)`, `list`, `search(filter)` | Inspect runs |
| `result(id, timeout:)` | Wait for the output; raises `WorkflowFailed` |
| `cancel`, `terminate`, `retry_step`, `cancel_scope(id, scope, reason)` | Operator controls |
| `replay(id, definition)`, `migrate(id, definition, force:, repin:)` | Check and move runs onto new code |
| `continue_as_new(id)`, `runs`, `current_run` | Continue-as-new chains |
| `upsert_search_attributes(id, set, remove:)` | Change a run's attributes |
| `build_ids`, `promote_build`, `retire_build`, `pinned_counts`, `repin`, `repin_pinned` | Worker build ids |
| `retire(id)`, `prune(before)`, `archived(id)`, `archived_runs` | Retention and archive |

**Schedules** (`worker.schedules`): `create`, `list`, `page`, `describe`, `get`, `update`, `pause`, `resume`, `trigger`, `backfill`, `delete`.
