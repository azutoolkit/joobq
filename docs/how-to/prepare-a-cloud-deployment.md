---
description: Prepare a versioned worker artifact, runtime configuration, and cloud connection budget.
---

# Prepare a cloud deployment

*How-to · Core · Pro*

## Prerequisites

- A build pipeline that produces a versioned binary or image from `shard.lock` for the target OS and architecture.
- A private Redis endpoint reachable from the workers.

## Steps

1. Keep repository credentials (for Pro) in the build system, and Redis credentials, application secrets and `JOOBQ_PRO_LICENSE` in runtime secret management.
2. Inject `REDIS_URL` (a `rediss://` URL for TLS) and, for a private CA, mount it and set the trust options:

```sh
export REDIS_TLS_VERIFY=true
export REDIS_CA_FILE=/run/secrets/redis-ca.pem
export REDIS_POOL_SIZE=20
CRYSTAL_WORKERS=4 ./bin/worker
```
3. Budget Redis connections: `REDIS_POOL_SIZE` is per pool, per process, so multiply by every producer and worker replica and compare with your provider's limit.
4. Deploy with the [worker entry point](deploy-workers.md), then run these checks:

| Check | Evidence to collect |
| --- | --- |
| Admission and completion | A representative job or run id and its expected business result |
| TLS and credentials | Valid trust, rejected invalid credentials, a rehearsed rotation |
| Worker termination | Drain time, exit status, unfinished work put back |
| Redis interruption | Bounded failures, reconnection, reconciled uncertain outcomes |
| Capacity and restore | Measured latency and backlog, a successful isolated restore |

## Verify

Every row of the table has its evidence recorded.

## See also

- [Deploy on Kubernetes](deploy-on-kubernetes.md)
- [Set up Redis and recovery](redis-and-recovery.md)
