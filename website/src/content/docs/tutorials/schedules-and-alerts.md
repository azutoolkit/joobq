---
title: Schedules & Alerts
description: Run recurring jobs and workflow schedules, operate them from JoobQUI, and add an alert rule that tells you when dead letters pile up.
order: 3
product: console
---

There are three kinds of recurring work in the ecosystem. Pick by who must own the schedule:

| Need | Use | Fired by |
| --- | --- | --- |
| Repeated work inside one process | JoobQ `scheduler` block (`cron`, `every`) | That process |
| Cron and interval jobs you operate from the console | `schedulers:` in JoobQ's YAML | `joobqui-selfhosted --worker` |
| Durable workflow starts with overlap and catch-up rules | JoobQ Pro workflow schedules | A Pro `Worker` with its scheduler on |

## 1. A schedule in code (JoobQ core)

```crystal
JoobQ.configure do
  queue "reports", 1, DailyReportJob

  scheduler do
    cron("30 2 * * *") { DailyReportJob.enqueue(kind: "daily") }
    every 1.hour, CleanupJob, older_than_days: 7
  end
end
```

These loops live in the process that registers them. `every` calls the job's `perform` directly rather than enqueueing a fresh job, so it skips queue retries and runs can overlap. When you need normal queue processing, enqueue from a `cron` block as above, and register the schedule in one process only.

## 2. Schedules you operate from JoobQUI

The console's **Schedules** page lists the `schedulers:` section of the JoobQ YAML file that the web process and the workers both read:

```yaml
# config/joobq.production.yml (excerpt)
joobq:
  schedulers:
    - timezone: "America/New_York"
      cron_jobs:
        - pattern: "0 18 * * 1-5"
          job: "LedgerCloseJob"
          args: { region: "us" }
      recurring_jobs:
        - interval: "10 minutes"
          job: "SyncInventoryJob"
```

They are fired by the queue worker process, `./joobqui-selfhosted --worker`, never by the web process. For each schedule the page shows the pattern or interval read in its time zone, the next five runs and the last run. Operators can **Pause**, **Resume** and **Run now** (`POST /api/v1/schedules/:id/run`, rate limited). A schedule's id is derived from its job class, pattern, zone and arguments, so editing one gives it a new id and starts it unpaused.

## 3. A durable workflow schedule (JoobQ Pro)

```crystal
schedules = worker.schedules
schedules.create("ledger-close", "ledger-close",
  cron: "0 18 * * mon-fri", timezone: "America/New_York",
  overlap: JoobQPro::Workflows::OverlapPolicy::Skip,
  catchup_window_ms: 3_600_000_i64)

schedules.trigger("ledger-close")   # run now, obeying the overlap policy
schedules.backfill("ledger-close", Time.utc(2026, 10, 1), Time.utc(2026, 10, 7))
```

Each fire time starts exactly one run, with id `sched-<schedule>-<fire time ms>`, even if two schedulers race. `Skip` (the default) records a fire time as skipped while the previous run is open; `BufferOne`, `AllowAll` and `CancelPrevious` are the other policies. Missed fire times inside `catchup_window_ms` run after downtime, oldest first. In JoobQUI these are the **Workflow schedules** (`/api/v1/workflow-schedules`): operators pause, resume, trigger and backfill; admins create, change and delete.

## 4. Add an alert rule

Alert rules come from JoobQ Pro's alerting and are checked by the console every 30 seconds against the metrics the workers publish.

1. Open **Alerts** and create a rule (operator role).
2. Name it `Dead letters accumulating`, metric **Jobs dead** (`dead`), operator `>=`, threshold `1`.
3. Save. Let a job fail until it is dead-lettered; within a minute the rule fires.
4. **Acknowledge** it so your team knows someone is on it.

Metrics a rule can use include `error_rate_trend`, `failed_job_rate`, `current_size` (jobs waiting), `running_workers`, `dead`, `jobs_completed_per_second`, `job_wait_time` and `job_execution_time`. Rules apply to the whole system, not to one queue.

To be paged, an admin adds a **notification channel**: email, Slack (incoming webhook), PagerDuty (Events API v2) or a webhook signed with HMAC-SHA-256. Webhook and Slack URLs must be `https` and may not resolve to a private, loopback or link-local address. Only one console instance sends notifications at a time (a Redis lease).

## Next

- [Triage & redrive dead letters](/docs/how-to/triage-and-redrive-dead-letters)
- [REST API, webhooks & metrics](/docs/reference/rest-api-webhooks-and-metrics)
