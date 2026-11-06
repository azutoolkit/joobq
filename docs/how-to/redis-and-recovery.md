---
description: Protect queue history and prove that a backup can restore useful work.
---

# Set up Redis and recovery

*How-to · Core · Pro*

## Prerequisites

- A Redis server you configure yourself, or a managed Redis whose persistence and eviction settings you can choose.
- A place to keep encrypted backups.

## Steps

1. Give workers a TLS URL and the trust settings through your secret manager; measure the pool size you need rather than copying these values:

```sh
export REDIS_TLS_VERIFY=true
export REDIS_CA_FILE=/run/secrets/redis-ca.pem
export REDIS_POOL_SIZE=20
export REDIS_POOL_TIMEOUT=2.0
export REDIS_CONNECT_TIMEOUT=5.0
export REDIS_COMMAND_TIMEOUT=5.0
export REDIS_OPERATION_TIMEOUT=5.0
./bin/worker
```
2. On a self-managed Redis, turn on AOF with `fsync` on every write and refuse writes instead of evicting keys when memory is full:

```conf
appendonly yes
appendfsync always
maxmemory-policy noeviction
```
3. Take provider snapshots or coordinated backups of the RDB/AOF files together with their manifest; encrypt them and record the Redis version, application revision and snapshot time.
4. Rehearse a restore into an isolated endpoint, with producers and workers stopped. Compare the job and run ids you expect with what is there, then start a small workload and reconcile uncertain outcomes.
5. Rehearse a Redis restart, lost acknowledgements and disk pressure in staging.

## Verify

- `redis-cli CONFIG GET appendonly` answers `yes`, and `CONFIG GET maxmemory-policy` answers `noeviction`.
- The restore rehearsal brought back the jobs and runs you expected, and you have measured how long it took.

## See also

- [Reliability and recovery](../explanation/reliability-and-recovery.md)
- [Recover and migrate](recover-and-migrate.md)
