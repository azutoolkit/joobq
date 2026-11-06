---
description: Deploy a tested worker image with private Redis access and enough time to stop.
---

# Deploy on Kubernetes

*How-to · Core · Pro*

## Prerequisites

- An image of the [Pro worker entry point](deploy-workers.md), built with `-Dpreview_mt`, pushed with an immutable digest, able to run as UID 10001, with its shared libraries and CA trust inside (the manifest mounts the root filesystem read-only).
- An `orders` namespace, an `orders-worker` Secret with `REDIS_URL` (and `JOOBQ_PRO_LICENSE` if used), and a `redis-ca` ConfigMap with your provider's `ca.pem`. For a publicly trusted certificate, leave out the CA volume and `REDIS_CA_FILE`.
- Network policy that lets the worker reach Redis and its own dependencies.

## Steps

1. Save the manifest and replace the example image with your digest; CPU and memory values are placeholders to measure:

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
2. Apply it and wait for the rollout:

```sh
kubectl apply -f worker-deployment.yaml
kubectl -n orders rollout status deployment/orders-worker
kubectl -n orders logs deployment/orders-worker
```
3. Keep one replica and the `Recreate` strategy until you have tested recovery with overlapping workers ([Recover and migrate](recover-and-migrate.md)).

## Verify

- `kubectl -n orders rollout status deployment/orders-worker` reports the rollout complete.
- A canary job or run submitted through your application completes; a running Pod alone does not show that.
- Deleting the Pod lets it stop within the 45-second grace period (the entry point uses 20 s for Pro and 10 s for Core; both library defaults are 15 s).

## See also

- [Reliability and recovery](../explanation/reliability-and-recovery.md)
