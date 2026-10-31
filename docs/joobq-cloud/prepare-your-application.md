---
description: Prepare a versioned worker artifact, runtime configuration, and cloud connection budget.
---

# Prepare your application

Keep worker code portable by separating the artifact from its runtime configuration. The same tested binary can run on a VM or in a compatible container environment.

## Build a repeatable artifact

Commit `shard.lock`, build for the target OS and architecture, and deploy an immutable image digest or versioned binary. Use the [worker entry point](../production-deployment/deploy-workers.md) to register workflows and own shutdown without enqueueing new work at boot.

Private Pro repository credentials belong in the build system. Redis credentials, application secrets, and a Pro license where applicable belong in runtime secret management. Keep both out of committed manifests and final image layers.

## Connect to managed Redis

Use a compatible private Redis endpoint. Inject `REDIS_URL` through your secret manager; a TLS URL uses `rediss://`. If your provider needs a custom CA, mount it and configure the existing JoobQ options:

```sh
export REDIS_TLS_VERIFY=true
export REDIS_CA_FILE=/run/secrets/redis-ca.pem
export REDIS_POOL_SIZE=20
CRYSTAL_WORKERS=4 ./bin/worker
```

For a publicly trusted certificate, use the system trust store and omit the custom CA setting. Preserve hostname verification. Confirm that network policy allows the worker to reach Redis and its actual application dependencies.

Budget connections across all producers, worker replicas, and configured pools. `REDIS_POOL_SIZE=20` is a per-pool limit, not an account-wide total. Scaling replicas can exhaust a provider's connection quota before CPU becomes the bottleneck.

## Prove the deployment path

| Check | Evidence to collect |
| --- | --- |
| Admission and completion | A representative job/run ID and its expected business result |
| TLS and credentials | Valid trust, rejected invalid credentials, and a rehearsed rotation |
| Worker termination | Drain time, exit status, and recovery of unfinished work |
| Redis interruption | Bounded failures, reconnection, and reconciliation of uncertain outcomes |
| Capacity and restore | Measured latency/backlog plus a successful isolated restore |

A provider status page and a Redis `PING` do not cover these application paths. Use the [operations guide](../production-deployment/operate-and-upgrade.md) to choose useful alerts.

**Next:** [Deploy on Kubernetes](kubernetes.md) or [deploy a VM worker service](../production-deployment/deploy-workers.md).
