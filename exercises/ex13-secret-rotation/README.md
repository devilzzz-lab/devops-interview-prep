# Exercise 13 — Secret Rotation Outage

## Incident

```
Following Secret Manager rotation:
Error:    401 Unauthorized
App logs: Token validation failed

Kubernetes Secret last updated: 2 weeks ago
Secret rotated at:              08:55
```

## What happened

AWS rotated the secret. Kubernetes never got it. App kept sending the old token. Server rejected it.

## The 3 layers — all must update

```
Layer 1: AWS Secrets Manager          ← rotated ✅
Layer 2: External Secrets Operator    ← did NOT sync ❌  (refreshInterval not hit yet)
Layer 3: Kubernetes Secret            ← still old value ❌
          ↓
         Pod env var                  ← still old value ❌ (baked in at pod start)
          ↓
         App sends old token → 401 Unauthorized
```

---

## Root Cause Analysis

### Why did External Secrets not sync?

External Secrets Operator syncs on a `refreshInterval`. If the rotation happens between two sync cycles, the new value is not fetched until the next interval fires.

```bash
kubectl describe externalsecret payment-secret -n default
```

Expected output (broken state):

```
Spec:
  refreshInterval: 1h          ← only syncs once per hour!

Status:
  Refresh Time: 2026-05-10T07:00:00Z   ← last sync was 07:00
  Ready: True
```

Secret rotated at `08:55`. Next sync at `09:00`. 5 minute gap → outage.

### Why did the pod not get the new value even after sync?

Even after External Secrets syncs and updates the Kubernetes Secret, **pods do not automatically restart**.

The pod keeps reading the old env var it loaded at startup — env vars are baked in at pod creation time, they do not hot-reload.

> Exception: secrets mounted as **volume files** do auto-update within 60–90 seconds — no restart needed. Env vars do not.

---

## Step 1 — Confirm the problem

```bash
# Check ExternalSecret sync status and refresh interval
kubectl get externalsecret -n default
```

Expected output:

```
NAME             STORE       REFRESH INTERVAL   STATUS   READY
payment-secret   aws-store   1h                 Synced   True
```

```bash
# Check when Kubernetes secret was last updated
kubectl describe secret payment-secret -n default | grep "Annotations" -A3
```

```bash
# Check actual value in Kubernetes secret (base64 decoded)
kubectl get secret payment-secret -n default \
  -o jsonpath='{.data.token}' | base64 -d
```

```bash
# Check what AWS actually has right now
aws secretsmanager get-secret-value \
  --secret-id payment-secret \
  --region ap-south-1 \
  --query 'SecretString' \
  --output text
```

If the two outputs above differ → Kubernetes secret is stale. That is your gap.

---

## Step 2 — Immediate fix

### Force External Secrets to sync right now

```bash
kubectl annotate externalsecret payment-secret \
  force-sync=$(date +%s) \
  --overwrite -n default
```

Expected output:

```
externalsecret.external-secrets.io/payment-secret annotated
```

Wait 10–15 seconds, then verify:

```bash
kubectl get externalsecret payment-secret -n default
```

Expected output:

```
NAME             STORE       REFRESH INTERVAL   STATUS   READY
payment-secret   aws-store   1h                 Synced   True
```

Confirm Kubernetes secret now has the new value:

```bash
kubectl get secret payment-secret -n default \
  -o jsonpath='{.data.token}' | base64 -d
```

This should now match the value from AWS.

### Restart the pod to pick up the new secret

Env vars are baked in at startup — you must restart for them to reload:

```bash
kubectl rollout restart deployment payment-service -n default
```

Expected output:

```
deployment.apps/payment-service restarted
```

Watch it come up:

```bash
kubectl rollout status deployment payment-service -n default
```

Expected output:

```
deployment "payment-service" successfully rolled out
```

Verify app is healthy:

```bash
kubectl logs deployment/payment-service -n default --tail=20
```

Expected output (no more 401):

```
2026-05-10T09:05:00Z INFO Token validated successfully
2026-05-10T09:05:01Z INFO Application started
```

---

## Step 3 — Prevent recurrence (long-term fixes)

### Fix 1 — Reduce refreshInterval from 1h to 1m

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: payment-secret
  namespace: default
spec:
  refreshInterval: 1m          # ← was 1h, now 1m
  secretStoreRef:
    name: aws-store
    kind: ClusterSecretStore
  target:
    name: payment-secret
    creationPolicy: Owner
  data:
    - secretKey: token
      remoteRef:
        key: payment-secret
        property: token
```

```bash
kubectl apply -f externalsecret.yaml
```

### Fix 2 — Use volume mounts instead of env vars

Volume-mounted secrets auto-update within 60–90 seconds without restarting the pod. Env vars never auto-update.

```yaml
# deployment.yaml
spec:
  containers:
    - name: payment-service
      volumeMounts:
        - name: secret-volume
          mountPath: /etc/secrets
          readOnly: true
  volumes:
    - name: secret-volume
      secret:
        secretName: payment-secret
```

App reads the file at runtime instead of env var:

```python
# Instead of: os.environ['TOKEN']
with open('/etc/secrets/token') as f:
    token = f.read().strip()
```

Now when rotation happens → External Secrets updates the K8s secret → volume file updates automatically → no restart needed.

### Fix 3 — Event-driven sync via EventBridge + Lambda

Instead of waiting for the timer, trigger sync immediately when rotation fires:

```
AWS Secrets Manager rotation event
 ↓
EventBridge rule (on SecretRotationSucceeded)
 ↓
Lambda function
 ↓
kubectl annotate externalsecret payment-secret force-sync=$(date +%s)
```

This reduces the propagation gap from minutes to seconds.

### Fix 4 — Alert when ExternalSecret is out of sync

```yaml
groups:
  - name: external-secrets
    rules:
      - alert: ExternalSecretSyncLag
        expr: |
          time() - external_secrets_sync_calls_error_total > 300
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "ExternalSecret {{ $labels.name }} has not synced in 5 minutes"
```

---

## Summary — exact order of events

```
08:55  AWS Secrets Manager rotates secret → new value live
08:55  External Secrets Operator refreshInterval = 1h → next sync at 09:00 → skips
08:55  Kubernetes Secret stays stale (old value, 2 weeks old)
08:55  Pod env var stays stale (baked in at pod start, never reloaded)
08:55  App sends old token → 401 Unauthorized
```

---

## Key commands cheatsheet

```bash
# Diagnose
kubectl get externalsecret -n default
kubectl describe externalsecret payment-secret -n default
kubectl get secret payment-secret -n default -o jsonpath='{.data.token}' | base64 -d
aws secretsmanager get-secret-value --secret-id payment-secret --region ap-south-1

# Immediate fix
kubectl annotate externalsecret payment-secret force-sync=$(date +%s) --overwrite -n default
kubectl rollout restart deployment payment-service -n default
kubectl rollout status deployment payment-service -n default

# Verify
kubectl logs deployment/payment-service -n default --tail=20
```

---

## Interview answer (say this)

> "The 401 happened because secret rotation in AWS did not propagate to the application. There are three layers — AWS Secrets Manager, External Secrets Operator, and the Kubernetes Secret — and all three must be in sync. AWS rotated the secret, but External Secrets only checks on its refreshInterval, which was set to 1 hour. The rotation happened between two sync cycles so the Kubernetes secret was never updated. Even after it syncs, pods using environment variables won't pick up the new value — they need a restart since env vars are baked in at pod start. The immediate fix is force-annotating the ExternalSecret to trigger an immediate sync, then restarting the pod. Long-term: reduce the refreshInterval to 1 minute, switch to volume-mounted secrets so updates propagate automatically without restarts, and add an EventBridge trigger that forces sync immediately when AWS rotation fires."