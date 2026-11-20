---
description: The versions these docs describe, and the versions each part requires and is tested with.
---

# Compatibility

*Reference · Core · Pro · JoobQUI*

Every page of these docs describes the versions below. A page that says something changed in a version names it.

## Versions documented

| Component | Version | Source |
| --- | --- | --- |
| JoobQ (Core) | 0.5.6, tag `v0.5.6` | `joobq/shard.yml` |
| JoobQ Pro | 0.2.4, tag `v0.2.4` (commit `7e9a0a5`) | `joobq-pro/shard.yml` |
| JoobQUI | `master` of `azutoolkit/joobqui` | |
| Azu CLI | 0.1.62, tag `v0.1.62` | `azu_cli/shard.yml` |

## Requirements

| Component | Requires |
| --- | --- |
| JoobQ 0.5.6 | Crystal `>= 1.22.0`; shards `redis` (stefanwille/crystal-redis) and `cron_parser`. From 0.6.0, Redis 6.2 or newer (FIFO claims use `BLMOVE`/`LMOVE`) |
| JoobQ Pro 0.2.4 | Crystal `>= 1.22.0`; `joobq >= 0.5.6, < 0.6.0`; `redis ~> 2.9.1`; read access to the private `azutoolkit/joobq-pro` repository |
| JoobQUI self-hosted | PostgreSQL and Redis; a licence key, except with `JOOBQUI_LICENSE_DEV_BYPASS` in development |
| Redis | One server or a managed equivalent; not Redis Cluster |
| Opt-in Delivery runtime | Redis with `appendonly yes`, `appendfsync always`, `maxmemory-policy noeviction` (checked at start) |

## Tested with

| What | Crystal | Redis |
| --- | --- | --- |
| Core CI (`ci.yml`), the Redis range | 1.22.1 (`crystallang/crystal:1.22.1-alpine`) | 6.2.24 (the floor), 7.4.12, 8.0.6 |
| Core CI (`ci.yml`), the Crystal range | 1.22.0 (the floor) and `latest` (`crystallang/crystal:latest-alpine`; reported, not gating the release) | 8.0.6 |
| Documentation examples, Core (`ci.yml`) | 1.22.1 | 8.0.6 |
| Documentation examples, Pro | run locally with `--edition pro`, not in CI | any local `redis-server` |

Every Core CI row runs the whole spec suite, TLS and the Redis restart and outage smokes included. The Redis rows run with `REDIS_HOST`/`REDIS_PORT` and, on 6.2 and 8.0, also with `REDIS_URL`; Redis 7.4 is tested only without `REDIS_URL`. Redis 6.2 is the first release with `LMOVE`/`BLMOVE`, so it is the floor; CI uses its newest patch release, 6.2.24. The Crystal rows run on one Redis, so a pairing not listed (Crystal 1.22.0 with Redis 6.2, for one) is not tested.

**Not tested, so not claimed:** glibc (CI runs on Alpine, musl), ARM, macOS, Crystal nightly, Redis 7.0 to 7.2, Redis Cluster and Sentinel. `latest` is whatever Crystal release the image holds on the day of the run, and a failing `latest` leg does not stop a release: it is a report to read, so a newer Crystal than the floor is claimed only as far as the last green `latest` run.

The example fixtures in `examples/docs/` pin `joobq = 0.5.6` and `joobq_pro = 0.2.4` in their `shard.yml`, with the resolved graphs in `shard.lock`.

## See also

- [Open Source vs Pro vs JoobQUI feature matrix](feature-matrix.md)
- [Install JoobQ and its prerequisites](../how-to/install.md)
- [Documentation validation](../validation.md)
