---
description: Start with the installed version, then follow the job through its actual processing path.
---

# Troubleshooting

## The worker starts but processes nothing

Check the queue registry first. “Memoized 0 queues” means there are no configured queues to start. Require job files before registration, register their concrete types, and ensure the job's `@queue` matches the configured queue.

Next compare producer and worker Redis host, port, database, and TLS configuration. Confirm the enqueue call actually ran. Do not print credentials or rely on Redis connectivity as proof that a worker is alive.

## The TUI shows zero jobs

Use `azu jobs:status --json` from the application directory. Confirm the initializer is loadable and workers are registered/alive. Very short jobs may finish between polls; inspect completion history or logs rather than expecting a permanent processing count.

The released `forge` does not automatically start `WorkerRegistry`. An empty worker list is therefore possible even while jobs complete; see [release-specific notes](../introduction/compatibility.md#release-specific-integration-notes).

The legacy queue view does not automatically include Delivery receipts or Pro workflow history. Use the matching integration and [management guide](../pro/management.md). An unavailable provider is different from zero work.

## “Management tokens are required”

The management API was enabled without any nonempty role token. Either disable the API when it is not needed, or configure [management credentials](../configuration/access.md). Setting `rest_api_enabled = true` while logging “API disabled” does not disable it.

## Pro cannot be installed or activated

Verify private repository access in the same build environment running Shards. Keep tokens out of `shard.yml`. Check the Pro dependency graph and license configuration independently; these are different concerns. Follow [Adding Pro](../introduction/adding-pro.md).

## Compilation fails after an upgrade

Record `crystal --version`, `shard.lock`, and the complete `--error-trace`. Use Crystal 1.22.1 for these examples. Check that Core was not upgraded independently of Pro's pinned revision. Do not edit `lib/` as a permanent fix; update the dependency or application configuration and commit the lockfile.

## Jobs repeat or disappear from the DLQ

Retries and recovery can repeat attempts. Inspect the stable business identity and external result before replaying. The documented Redis DLQ does not enforce `dead_letter_ttl`. If records disappear, investigate replay, purge/reset operations, Redis eviction, and restore history rather than assuming the seven-day setting removed them. Define retention long enough for incident response and monitor DLQ growth.

## Redis TLS or pool failures

Check certificate hostname/trust, credentials, Redis database, connection limits, and timeout budgets. Never treat turning off TLS verification as a production fix. See [Redis connections](../configuration/redis.md).

When reporting an issue, include redacted configuration, exact revisions, processing API, reproduction steps, and observed versus expected outcomes.
