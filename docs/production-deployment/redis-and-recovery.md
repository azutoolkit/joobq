---
description: Protect queue history and prove that a backup can restore useful work.
---

# Redis and recovery

Treat Redis as application state. Queue entries, delayed work, leases, receipts, and workflow histories can all matter during recovery. A cache-style eviction policy is a poor fit for this data.

## Connect securely

Inject `REDIS_URL` from your secret manager using a `rediss://` endpoint. Configure trust and pool limits explicitly; these values are starting points to measure, not universal tuning recommendations.

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

Validate the certificate hostname and the ACL commands used by your enabled features, including Lua scripts. Use separate credentials and endpoints for environments. A successful connection does not validate workflow dispatch, reconciliation, or failover behavior.

## Choose persistence and capacity

For a self-managed Redis instance, this configuration fragment favors durable acknowledgments and preserves keys when memory is exhausted:

```conf
appendonly yes
appendfsync always
maxmemory-policy noeviction
```

Set memory and disk capacity for your workload and retained histories; `noeviction` turns exhaustion into write failures rather than silently deleting work. Measure the latency cost of `appendfsync always`. Replication and persistence settings still do not guarantee that every acknowledged write survives every failover.

## Make recovery routine

1. Take provider-supported snapshots or coordinated Redis backups. Preserve the required RDB/AOF files and manifest together; do not copy a changing multipart AOF directory blindly.
2. Encrypt backups, restrict access, and keep a tested retention policy. Record Redis version, application revision, snapshot time, and the corresponding persistence settings.
3. Restore into an isolated endpoint with producers and workers initially stopped. Never aim a rehearsal at production.
4. Compare expected run/job identifiers and states before starting compatible workers. Account for writes after the backup and effects already committed in external systems.
5. Resume a small workload, reconcile uncertain outcomes, and measure actual RPO/RTO before reopening admission.

Include Redis restart, lost acknowledgments, disk pressure, and failed failover in staging exercises. Managed providers may restrict commands or alter failover semantics; validate the exact service tier you plan to use.

**Next:** [Operate and upgrade](operate-and-upgrade.md) and the [incident recovery checklist](../best-practices/recovery.md).
