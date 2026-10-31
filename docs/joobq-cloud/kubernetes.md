---
description: Deploy a tested worker image with private Redis access and enough time to stop.
---

# Deploy on Kubernetes

Use this as a starting manifest for the [Pro worker entry point](../production-deployment/deploy-workers.md). It registers the `orders` workflow and owns SIGTERM handling. Build and push its image first; replace the example image with your tested immutable image digest before deployment.

## Prepare configuration

Create an `orders` namespace, an `orders-worker` Secret containing `REDIS_URL` and, where applicable, `JOOBQ_PRO_LICENSE`, and a `redis-ca` ConfigMap containing your provider's `ca.pem`. Manage secret values outside Git. For a publicly trusted certificate, omit the CA volume and `REDIS_CA_FILE` variable.

The worker needs private access to Redis and its application dependencies. Configure network policies and provider firewall rules for that topology; do not expose the management API just to make a probe convenient.

{% code title="worker-deployment.yaml — replace the image before applying" %}
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: orders-worker
  namespace: orders
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: orders-worker
  template:
    metadata:
      labels:
        app: orders-worker
    spec:
      automountServiceAccountToken: false
      terminationGracePeriodSeconds: 45
      containers:
        - name: worker
          image: registry.example.com/orders/worker:replace-with-tested-release
          command: ["/app/bin/worker"]
          securityContext:
            runAsNonRoot: true
            runAsUser: 10001
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop: ["ALL"]
          envFrom:
            - secretRef:
                name: orders-worker
          env:
            - name: CRYSTAL_WORKERS
              value: "2"
            - name: REDIS_TLS_VERIFY
              value: "true"
            - name: REDIS_CA_FILE
              value: /etc/redis-ca/ca.pem
            - name: REDIS_POOL_SIZE
              value: "20"
          resources:
            requests:
              cpu: "1"
              memory: 256Mi
            limits:
              cpu: "2"
              memory: 512Mi
          volumeMounts:
            - name: redis-ca
              mountPath: /etc/redis-ca
              readOnly: true
      volumes:
        - name: redis-ca
          configMap:
            name: redis-ca
```
{% endcode %}

Build the image with `-Dpreview_mt` for Crystal 1.22.1 if you intend `CRYSTAL_WORKERS=2` to select two runtime threads. CPU and memory values are illustrative. Measure your workload and account for connection buffers, input sizes, and workflow history. The image must include its required shared libraries and CA trust, and allow UID 10001 to execute the binary. The example uses a read-only root filesystem; mount deliberate writable storage if your application needs scratch files or a local archive.

## Roll out, then prove progress

After provisioning the prerequisites and replacing the image:

```sh
kubectl apply -f worker-deployment.yaml
kubectl -n orders rollout status deployment/orders-worker
kubectl -n orders logs deployment/orders-worker
```

A running Pod confirms process scheduling, not successful order completion. Submit a representative canary through your application and inspect its result. Add health checks based on the signals your application actually exposes; this example has no HTTP health endpoint.

The initial single replica and `Recreate` strategy avoid automatic overlapping worker processes during rollout and cause a processing pause. Before enabling rolling updates or more replicas, test the installed runtime's processing recovery, duplicate-safe effects, connection budget, and Pro build-pinning policy. Legacy queues, opt-in Delivery, and Pro workflows have different recovery paths. In particular, [legacy startup recovery](../best-practices/recovery.md#know-the-legacy-startup-recovery-limit) can move another consumer's active job and only reclaims one processing entry per start.

The 45-second grace period leaves margin around the example's 20-second Pro and 10-second Core shutdown budgets. Rehearse termination under load; Kubernetes can force a kill after the grace period.

**Next:** [Operate and upgrade](../production-deployment/operate-and-upgrade.md).
