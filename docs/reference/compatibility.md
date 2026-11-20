---
description: What JoobQ's version numbers promise, how deprecations work, which Redis, Crystal and JoobQ versions are supported, and how security fixes are announced.
---

# Compatibility and support policy

*Reference · Core · Pro · JoobQUI*

Every page of these docs describes the versions below. A page that says something changed in a version names it.

## Versions documented

| Component | Version | Source |
| --- | --- | --- |
| JoobQ (Core) | 0.8.1, tag `v0.8.1` | `joobq/shard.yml` |
| JoobQ Pro | 0.7.5, needs `joobq >= 0.7.2, < 0.8.0` (as of its `shard.yml`) | `joobq-pro/shard.yml` |
| JoobQUI | `master` of `azutoolkit/joobqui` | |
| Azu CLI | 0.1.62, tag `v0.1.62` | `azu_cli/shard.yml` |

`scripts/check_docs.py` fails when the JoobQ (Core) row differs from `version:` in `shard.yml`, so a release that does not update this page does not pass the docs check. It checks the JoobQ Pro row the same way against `shard.yml` of a `joobq-pro` checkout next to this repository (or the one `JOOBQ_PRO_CHECKOUT` names) and, when there is none, prints `Pro row not checked (no joobq-pro checkout)` and goes on. `joobq-pro` is private, so CI has no checkout and never checks the Pro row; the Pro version is the one in `joobq-pro`'s `shard.yml` when this page was last edited with a checkout at hand. JoobQUI's and Azu CLI's rows are never checked.

JoobQ **0.8.0** carries the breaking changes listed under *0.8.0* in the changelog (the `joobq:v1:` keyspace move, `allow_plaintext_payloads` defaulting to `false`, redacted API payloads, the removal of `JoobQ.scheduler`), a minor release under the policy below. JoobQ Pro's `joobq >= 0.7.2, < 0.8.0` constraint (and JoobQUI's `= 0.7.2`) has not been widened yet: it moves with their move to the `joobq:v1:` keys, so neither can pick up 0.8.0 before then.

## Supported versions

**Only the latest release is supported**, and it is the only one that receives fixes, security fixes included. Fixes ship in new releases only: there are no patches for older ones, no back-ports and no long-term-support line. The [changelog](https://github.com/azutoolkit/joobq/blob/master/CHANGELOG.md) lists every release. Pin a release tag in production and move to the newest one when it ships. JoobQUI follows the same rule ([Supported versions](https://github.com/azutoolkit/joobqui/blob/master/docs/site/operate/upgrading.md)).

## Requirements

| Component | Requires |
| --- | --- |
| JoobQ | Crystal `>= 1.22.0` (`shard.yml`); shards `redis` (stefanwille/crystal-redis) and `cron_parser`; Redis 6.2 or newer (FIFO claims use `BLMOVE`/`LMOVE`) |
| JoobQ Pro | Crystal `>= 1.22.0`; `joobq >= 0.7.2, < 0.8.0`; `redis ~> 2.9.1`; read access to the private `azutoolkit/joobq-pro` repository |
| JoobQUI self-hosted | PostgreSQL and Redis; a licence, except with `JOOBQUI_LICENSE_DEV_BYPASS` in development |
| Redis | One server or a managed equivalent; not Redis Cluster |
| Opt-in Delivery runtime | Redis with `appendonly yes`, `appendfsync always`, `maxmemory-policy noeviction` (checked at start) |

A version below these floors is unsupported: it may work, and a problem on it is not fixed.

## Tested with

Supported means the floor above; **tested** means what CI runs. Only these combinations are verified:

| What | Crystal | Redis |
| --- | --- | --- |
| Core CI (`ci.yml`), the Redis range | 1.22.1 (`crystallang/crystal:1.22.1-alpine`) | 6.2.24 (the floor), 7.4.12, 8.0.6 |
| Core CI (`ci.yml`), the Crystal range | 1.22.0 (the floor) and `latest` (`crystallang/crystal:latest-alpine`; reported, not gating the release) | 8.0.6 |
| Documentation examples, Core (`ci.yml`) | 1.22.1 | 8.0.6 |
| Documentation examples, Pro | run locally with `--edition pro`, not in CI | any local `redis-server` |

Every Core CI row runs the whole spec suite, TLS and the Redis restart and outage smokes included. The Redis rows run with `REDIS_HOST`/`REDIS_PORT` and, on 6.2 and 8.0, also with `REDIS_URL`; Redis 7.4 is tested only without `REDIS_URL`. Redis 6.2 is the first release with `LMOVE`/`BLMOVE`, so it is the floor; CI uses its newest patch release, 6.2.24. The Crystal rows run on one Redis, so a pairing not listed (Crystal 1.22.0 with Redis 6.2, for one) is not tested.

**Not tested, so not claimed:** glibc (CI runs on Alpine, musl), ARM, macOS, Crystal nightly, Redis 7.0 to 7.2, Redis Cluster and Sentinel. `latest` is whatever Crystal release the image holds on the day of the run, and a failing `latest` leg does not stop a release: it is a report to read, so a newer Crystal than the floor is claimed only as far as the last green `latest` run.

The example fixtures in `examples/docs/` pin `joobq = 0.5.6` and `joobq_pro = 0.2.4` in their `shard.yml`, with the resolved graphs in `shard.lock`.

## What a version number means

JoobQ uses [semantic versioning](https://semver.org). The public API is what [Public API](public-api.md) lists as frozen, together with the surfaces below. Anything else, including a member that is public in the source but not on that page, may change in any release.

| Surface | Covered by the policy |
| --- | --- |
| Crystal API | The members on [Public API](public-api.md): names, argument names and types, return types |
| Configuration | YAML keys, `JOOBQ_*` and `REDIS_*` variables and `JoobQ.configure` properties of [Configuration](configuration.md), with their meaning; a changed default counts as a change |
| HTTP management API | Paths, methods, roles, status codes and JSON field names of [Core API](core-api.md); a new field may be added |
| Redis keyspace | The layout of the keys under `joobq:v1:` (names and types), for data compatibility; the Crystal classes that build them (`JoobQ::Keys`, `JoobQ::RedisStore`) are not frozen. A different layout gets a new prefix and a migration; the old one is never reused for other data |
| Job format | The stored job's `"v"` field, for data compatibility. A reader accepts every version up to its own and refuses a greater one. A new format version is a breaking change |
| Error codes | A `JQ-nnn` code keeps its meaning; a code no longer raised is kept, never renumbered or reused |

**Not covered:** Preview features (`JoobQ::Delivery::Runtime`, workflow pages marked Preview), members marked `:nodoc:`, log message text, benchmark numbers, the text of error messages (use the `JQ-` code), the exact timing of background loops, and warnings the compiler prints.

### Before 1.0

- A **patch** release (`0.7.2` to `0.7.3`) fixes bugs and never breaks a frozen member.
- A **minor** release (`0.7.x` to `0.8.0`) may break a frozen member, change a default, move the keyspace or raise the format version. Each such change is listed under **Changed (breaking)** in the changelog with an upgrade note, and says what to do.
- JoobQ Pro and JoobQUI declare which JoobQ minor they need (`>= 0.7.2, < 0.8.0`); upgrade them together with JoobQ across a minor.

### From 1.0

- A **patch** release fixes bugs.
- A **minor** release adds features and may deprecate; it never breaks a frozen member, changes a documented default, or changes the keyspace or the format version in a way an older reader cannot handle.
- A **major** release may remove what was deprecated, change defaults, and move the keyspace or format version, with a migration path in the changelog and the docs.

## Deprecation

1. A member is deprecated in a **minor** release (N): it gets `@[Deprecated("Use ...")]`, so the compiler warns at every call site; it is listed under **Deprecated** on [Public API](public-api.md) with its replacement; and the changelog says so under **Changed**.
2. It keeps working, with the same behavior, for **at least two more minor releases** (removed in N+2 at the earliest) **and at least 90 days**. From 1.0 it is removed only in a **major** release.
3. Removal is announced in the changelog under **Changed (breaking)** with the replacement.
4. Exceptions: a security fix may change or remove a member in the same release that announces it, and a member that never worked (it failed to compile or did nothing) may be removed at once, with a changelog entry.

A behavior or configuration default is not "deprecated" and removed later: it changes in a release the policy allows, with an upgrade note.

## Upgrading

Read the changelog entries between your version and the target, newest first, and act on each **Changed (breaking)** and **Deprecated** item. The 0.7 keyspace move has its own steps (stop every process, run `JoobQ.migrate_keyspace!`); see [Recover and migrate](../how-to/recover-and-migrate.md) and [Operate and upgrade](../how-to/operate-and-upgrade.md). Upgrade JoobQ Pro and JoobQUI to the versions that declare your JoobQ version.

## Security fixes

Vulnerabilities are reported privately, as [SECURITY.md](https://github.com/azutoolkit/joobq/blob/master/SECURITY.md) describes. A fix ships only in a new release of the latest version, which is announced with the release in the changelog (and a GitHub security advisory for a confirmed vulnerability), crediting the reporter if they ask. Upgrading to the latest release is the only supported way to receive it. The deprecation window does not delay a security fix.

## See also

- [Public API](public-api.md)
- [Open Source vs Pro vs JoobQUI feature matrix](feature-matrix.md)
- [Install JoobQ and its prerequisites](../how-to/install.md)
- [Documentation validation](../validation.md)
