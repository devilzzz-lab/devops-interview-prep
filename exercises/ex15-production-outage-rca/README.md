# Exercise 15 — Complete Production Outage RCA

## 1. Timeline

| Time  | Event                                                                  |
| ----- | ---------------------------------------------------------------------- |
| 08:55 | AWS Secret Manager rotates Redis password → new value live in AWS      |
| 08:55 | External Secrets Operator refreshInterval not hit → skips sync         |
| 08:55 | Kubernetes secret stays stale → still holds old Redis password         |
| 09:00 | Deployment completes → ArgoCD reports Healthy                          |
| 09:00 | New pods start → load Redis password from stale K8s secret             |
| 09:05 | Pods try to connect to Redis with old password → Authentication failed |
| 09:05 | Application cannot connect to Redis → HTTP 503                         |
| 09:05 | Users impacted                                                         |

---

## 2. Root Cause

Secret Manager rotated the Redis password at 08:55 — 5 minutes before deployment.

External Secrets Operator did not sync in that 5-minute window (refresh interval not hit). The Kubernetes secret kept the old password. When the new pods started at 09:00, they loaded the stale K8s secret and used the old password to connect to Redis. Redis rejected it with Authentication failed.

### Why everything appeared Healthy

* ArgoCD Healthy — pods were running, deployment succeeded
* Pods Running — containers started fine, no crash yet
* Ingress Healthy — routing was fine

The failure was invisible to all infra health checks. The bug was inside the secret value, not the infrastructure.

---

## 3. Investigate — each layer

### Layer 1 — ArgoCD

```bash
argocd app get payment-service
```

Expected output:

```text
Health:  Healthy
Sync:    Synced
```

ArgoCD is fine. Deployment completed successfully. This rules out a deployment issue.

---

### Layer 2 — Secret Manager

```bash
# Check when rotation happened
aws secretsmanager describe-secret \
  --secret-id redis-password \
  --region ap-south-1 \
  --query '{LastRotated: LastRotatedDate, LastChanged: LastChangedDate}'
```

Expected output:

```json
{
  "LastRotated": "2026-05-10T08:55:00Z",
  "LastChanged": "2026-05-10T08:55:00Z"
}
```

Rotation happened at 08:55 — 5 minutes before deployment. This is your smoking gun.

```bash
# Get the current value in AWS
aws secretsmanager get-secret-value \
  --secret-id redis-password \
  --region ap-south-1 \
  --query 'SecretString' \
  --output text
```

Copy this value — you'll compare it with the K8s secret next.

---

### Layer 3 — External Secrets

```bash
kubectl get externalsecret -n default
```

Expected output:

```text
NAME             STORE       REFRESH INTERVAL   STATUS   READY
redis-secret     aws-store   1h                 Synced   True
```

refreshInterval: 1h — that's the problem. Rotation happened between sync cycles.

```bash
kubectl describe externalsecret redis-secret -n default | grep "Refresh Time"
```

Expected output:

```text
Refresh Time: 2026-05-10T08:00:00Z
```

Last sync was at 08:00. Rotation happened at 08:55. Next sync at 09:00 — but deployment already happened.

---

### Layer 4 — Kubernetes Secret

```bash
# Get the current value in K8s secret
kubectl get secret redis-secret -n default \
  -o jsonpath='{.data.password}' | base64 -d
```

Compare this with what AWS has.

If they differ → K8s secret is stale — confirmed.

```bash
# Check when K8s secret was last updated
kubectl describe secret redis-secret -n default | grep "Last Updated\|Age"
```

Expected output:

```text
Age: 1h
```

← hasn't updated since the last sync, before rotation.

---

### Layer 5 — Application

```bash
kubectl logs deployment/payment-service -n default --tail=30
```

Expected output:

```text
2026-05-10T09:05:01Z ERROR Cannot connect to Redis
2026-05-10T09:05:01Z ERROR Authentication failed
2026-05-10T09:05:02Z ERROR Redis connection refused
```

```bash
# Confirm which secret the pod loaded at startup
kubectl exec -it <pod-name> -n default -- env | grep REDIS
```

Expected output:

```text
REDIS_PASSWORD=old-stale-password-value
```

Compare with AWS value — they don't match. Confirmed.

---

### Layer 6 — Redis

```bash
kubectl logs deployment/redis -n default --tail=20
```

Expected output:

```text
2026-05-10T09:05:01Z WARN Client 10.0.1.55:42310 AUTH failed: wrong password
2026-05-10T09:05:01Z WARN Client 10.0.1.55:42311 AUTH failed: wrong password
```

Redis is working fine — it's rejecting the wrong password. Not a Redis problem.

---

## 4. Immediate Fix

### Step 1 — Force External Secrets sync now

```bash
kubectl annotate externalsecret redis-secret \
  force-sync=$(date +%s) \
  --overwrite -n default
```

Expected output:

```text
externalsecret.external-secrets.io/redis-secret annotated
```

Wait 15 seconds, verify K8s secret updated:

```bash
kubectl get secret redis-secret -n default \
  -o jsonpath='{.data.password}' | base64 -d
```

This should now match the AWS value.

---

### Step 2 — Restart pods to load new secret

```bash
kubectl rollout restart deployment payment-service -n default
```

Expected output:

```text
deployment.apps/payment-service restarted
```

```bash
kubectl rollout status deployment payment-service -n default
```

Expected output:

```text
deployment "payment-service" successfully rolled out
```

---

### Step 3 — Verify Redis connection restored

```bash
kubectl logs deployment/payment-service -n default --tail=20
```

Expected output:

```text
2026-05-10T09:08:00Z INFO Redis connection established
2026-05-10T09:08:01Z INFO Application started successfully
```

```bash
# Confirm HTTP 503 is gone
curl -I https://your-app-domain.com/api/health
```

Expected output:

```text
HTTP/1.1 200 OK
```

---

## 5. Long-term Prevention

### Fix 1 — Reduce ExternalSecret refreshInterval

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: redis-secret
  namespace: default
spec:
  refreshInterval: 1m
  secretStoreRef:
    name: aws-store
    kind: ClusterSecretStore
  target:
    name: redis-secret
  data:
    - secretKey: password
      remoteRef:
        key: redis-password
        property: password
```

---

### Fix 2 — Add deployment pre-check in CI/CD pipeline

Before every deployment, verify K8s secret matches AWS:

```bash
# In your GitHub Actions workflow, before argocd sync:

AWS_SECRET=$(aws secretsmanager get-secret-value \
  --secret-id redis-password --query 'SecretString' --output text)

K8S_SECRET=$(kubectl get secret redis-secret \
  -o jsonpath='{.data.password}' | base64 -d)

if [ "$AWS_SECRET" != "$K8S_SECRET" ]; then
  echo "SECRET MISMATCH — forcing ExternalSecret sync before deploy"
  kubectl annotate externalsecret redis-secret \
    force-sync=$(date +%s) --overwrite
  sleep 15
fi
```

---

### Fix 3 — Use volume mounts instead of env vars

Volume-mounted secrets auto-update in 60–90 seconds.

App reads file at runtime — no restart needed.

```yaml
spec:
  containers:
    - name: payment-service
      volumeMounts:
        - name: redis-secret
          mountPath: /etc/secrets
          readOnly: true

  volumes:
    - name: redis-secret
      secret:
        secretName: redis-secret
```

---

### Fix 4 — EventBridge trigger on rotation

```text
AWS Secret rotation event
          ↓
    EventBridge rule
          ↓
         Lambda
          ↓
kubectl annotate externalsecret redis-secret force-sync=$(date +%s)
```

Sync happens within seconds of any rotation — not on a timer.

---

## 6. Monitoring Improvements

### Add alert: K8s secret out of sync with AWS

```yaml
- alert: SecretSyncLag
  expr: time() - external_secrets_sync_calls_error_total > 120
  for: 1m
  labels:
    severity: critical
  annotations:
    summary: "ExternalSecret {{ $labels.name }} not synced in 2 minutes"
```

---

### Add alert: Redis connection failure rate

```yaml
- alert: RedisConnectionFailure
  expr: rate(redis_connection_errors_total[2m]) > 0.1
  for: 1m
  labels:
    severity: critical
  annotations:
    summary: "Redis connection errors on {{ $labels.instance }}"
```

---

### Add healthcheck that tests Redis connection

```yaml
# In deployment.yaml
livenessProbe:
  exec:
    command: ["redis-cli", "-a", "$(REDIS_PASSWORD)", "ping"]
  initialDelaySeconds: 5
  periodSeconds: 10
```

This makes the pod restart if Redis connection fails — instead of serving 503s silently.

---

# Interview answer (say this)

> "At 08:55 AWS Secret Manager rotated the Redis password. The External Secrets Operator had a 1-hour refresh interval and didn't pick up the rotation. The Kubernetes secret stayed stale. At 09:00 deployment completed — ArgoCD showed Healthy, pods were Running, Ingress was Healthy — everything looked fine because the failure was invisible to infra health checks. At 09:05, the new pods tried to connect to Redis using the old password from the stale K8s secret. Redis rejected it with Authentication failed, and the app started returning 503. To diagnose, I compare the value in AWS Secrets Manager with the value in the K8s secret — if they differ, that's the gap. Immediate fix is force-annotating the ExternalSecret to trigger a sync, then restarting the pods. Long-term: reduce refreshInterval to 1 minute, add a pre-deployment secret parity check in the pipeline, switch to volume-mounted secrets so they update without restarts, and add an EventBridge trigger so sync fires immediately on every rotation — not on a timer."
