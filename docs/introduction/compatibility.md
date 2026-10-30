---
description: Choose a reproducible Core or Pro dependency graph before copying examples.
---

# Compatibility and feature availability

The two quick starts use different dependency graphs. Keep their lockfiles; do not assume a newer Core revision is interchangeable with Pro's pinned dependency.

## Documentation baseline

| Component | Baseline | Notes |
| --- | --- | --- |
| Crystal | 1.22.1 | Compiler used to compile and execute these examples |
| JoobQ | Tag `v0.5.1`, commit `b7511747f60df2cafdc8bee53118386b2c47a08e` | Its historical `shard.yml` declares `0.4.2`; identify it by tag and resolved revision, not that field alone |
| JoobQ Pro | Tag `v0.2.0`, commit `0c6655acb6c4372bac55992de2f0d7cd73261b24` | Requires authorized access to the private repository |
| Core used by Pro | `2e5be17d145ead36d2d419c8ba4e4029837dd9c5` | Pro's release pins this revision; do not override it with Core `v0.5.1` |
| Azu CLI | `v0.1.59` command interfaces | Optional; its operator adapters compile against the application's installed shards |
| Redis | 7.4.12 and 8.0.6 in the existing integration matrix | TLS, persistence and authentication are deployment settings, not consequences of installing a shard |

## Release-specific integration notes

- Core `v0.5.1` includes typed `config.queue` registrations in `forge`. Pro `v0.2.0` pins an earlier Core revision: use `QueueFactory.register_job_type` plus `config.queue_configs` (or the generated YAML registration) for legacy jobs. The [observability fixture](../../examples/docs/pro/observability.cr) demonstrates that compatible path.
- `WorkerRegistry` is available, but these Core baselines do **not** start it automatically from `forge`. The CLI can show completed jobs while its worker list is empty. A custom worker entry point must own registry startup/shutdown if you need heartbeat data; never start it in an inspection initializer.

## Read the labels

- **Core:** available through the Core baseline.
- **Pro:** implemented by the Pro baseline; install the Pro shard and configure the feature.
- **Preview:** opt-in architecture that needs workload and migration validation. Presence in a release does not imply a completed production cutover.
- **Unavailable:** no provider or supported implementation exists in the selected setup. It does not mean zero activity.

| Capability | Availability | Boundary |
| --- | --- | --- |
| Queue/Worker jobs, delayed retries, DLQ, Redis TLS | Core | Legacy processing API |
| Management roles, worker registry, CLI inspection | Core | Metrics depend on the installed API and active workers |
| Delivery leases, receipts and explicit admission | Core / Preview | Separate namespace and runtime; `Job.enqueue` does not opt in |
| Workflow histories, signals, schedules, compensation | Pro | History lives in Redis; PostgreSQL history is not supplied by these versions |
| Durable batch and uniqueness services | Pro / Preview | Explicit Delivery runtime and reconciliation |
| Percentile collection and alerting | Pro | Must be configured; no automatic external telemetry export is implied |
| Reviewed replay and queue compare-and-set APIs | Unreleased relative to these baselines | Added after Core `v0.5.1`; do not use them in release examples |

## Upgrade deliberately

Inspect `shard.lock` before and after an upgrade, compile your workers, and rehearse retry/replay behavior in staging. Do not move a legacy queue into Delivery by changing only a configuration flag. Follow the [Delivery guide](../core/delivery.md) and [recovery checklist](../best-practices/recovery.md).

Source evidence: [Core release](https://github.com/azutoolkit/joobq/tree/v0.5.1), [Pro release](https://github.com/azutoolkit/joobq-pro/tree/v0.2.0) (authorized access required), and [CLI release](https://github.com/azutoolkit/azu_cli/tree/v0.1.59). Example validation is recorded in [Validation](../validation.md).
