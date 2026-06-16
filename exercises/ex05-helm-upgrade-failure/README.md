# Exercise 5 — Helm Upgrade Failure (Immutable Field Error)

## Incident

A production deployment failed during a Helm upgrade.

Command executed:

```bash
helm upgrade payment-service .
```

Error:

```text
UPGRADE FAILED:
cannot patch Deployment:
spec.selector:
Invalid value:
field is immutable
```

---

# Current Chart

## Version 1

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-service
spec:
  selector:
    matchLabels:
      app: payment
```

---

## Version 2

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-service
spec:
  selector:
    matchLabels:
      app: payment-v2
```

---

# Architecture (Before Upgrade)

```text
Helm Chart v1
│
└── selector:
      app=payment
            │
            ▼
 Kubernetes Deployment
            │
            ▼
      Pod Labels
      app=payment
```

---

# Architecture (Upgrade Attempt)

```text
Helm Chart v2
│
└── selector:
      app=payment-v2
            │
            ▼
Helm Upgrade
            │
            ▼
Kubernetes API Server
            │
            ▼
Reject Request

ERROR:
spec.selector is immutable
```

---

# Root Cause Analysis

## Q1 — What changed?

The Deployment selector was modified.

Version 1:

```yaml
selector:
  matchLabels:
    app: payment
```

Version 2:

```yaml
selector:
  matchLabels:
    app: payment-v2
```

The selector determines which pods belong to a Deployment.

Kubernetes does not allow changing this value after the Deployment is created.

---

## Q2 — Why are immutable field errors occurring?

Certain Kubernetes fields are marked as immutable because changing them could break ownership relationships.

For Deployments:

```yaml
spec.selector
```

is immutable.

The Deployment uses the selector to identify:

```text
Deployment
    │
    ▼
ReplicaSets
    │
    ▼
Pods
```

If Kubernetes allowed selector changes:

```text
Deployment
app=payment

        ▼

Changed To

app=payment-v2
```

The Deployment could suddenly lose track of its existing ReplicaSets and Pods.

To prevent this, Kubernetes blocks the update entirely.

---

## Common Immutable Fields

### Deployment

```yaml
spec.selector
```

---

### StatefulSet

```yaml
spec.volumeClaimTemplates
```

---

### Service

```yaml
spec.clusterIP
```

---

### PersistentVolumeClaim

```yaml
spec.storageClassName
```

(Some changes are allowed, but many are restricted.)

---

# How to Confirm the Issue

## Inspect Current Deployment

```bash
kubectl get deploy payment-service -o yaml
```

Look for:

```yaml
selector:
  matchLabels:
    app: payment
```

---

## Render Helm Template

```bash
helm template payment-service .
```

Expected output:

```yaml
selector:
  matchLabels:
    app: payment-v2
```

---

## Compare Current vs Desired

```text
Current Cluster

app=payment


Helm Upgrade Wants

app=payment-v2
```

Mismatch detected.

---

## Use Helm Diff

```bash
helm diff upgrade payment-service .
```

Expected output:

```diff
- app: payment
+ app: payment-v2
```

This immediately identifies the immutable field change.

---

# Safe Upgrade Approach

## Option A — Keep Selector Stable (Recommended)

Never change:

```yaml
spec:
  selector:
```

Instead:

```yaml
selector:
  matchLabels:
    app: payment
```

remains unchanged forever.

Only update pod template labels:

```yaml
template:
  metadata:
    labels:
      app: payment
      version: v2
```

Example:

```yaml
spec:
  selector:
    matchLabels:
      app: payment

  template:
    metadata:
      labels:
        app: payment
        version: v2
```

Helm upgrade works successfully.

---

## Option B — Delete and Recreate Deployment

If selector must change:

```bash
kubectl delete deployment payment-service
```

Then:

```bash
helm upgrade payment-service .
```

or

```bash
helm install payment-service .
```

However:

```text
Risk:
Pods temporarily disappear
Possible downtime
```

Not recommended for production unless planned.

---

## Option C — Blue/Green Deployment (Production Safe)

Create a new Deployment.

Current:

```yaml
name: payment-service
selector:
  app: payment
```

New:

```yaml
name: payment-service-v2
selector:
  app: payment-v2
```

Architecture:

```text
Existing Deployment
app=payment
      │
      ▼
    Pods

New Deployment
app=payment-v2
      │
      ▼
    Pods
```

After validation:

```text
Traffic
   │
   ▼
payment-service-v2
```

Then retire the old deployment.

This avoids downtime.

---

# Production Recovery Steps

## Step 1 — Verify Current Release

```bash
helm list -A
```

---

## Step 2 — Inspect Deployment

```bash
kubectl get deploy payment-service -o yaml
```

---

## Step 3 — Check Helm History

```bash
helm history payment-service
```

Example:

```text
REVISION STATUS
1        deployed
2        failed
```

---

## Step 4 — Roll Back If Needed

```bash
helm rollback payment-service 1
```

Verify:

```bash
kubectl rollout status deployment/payment-service
```

Expected:

```text
deployment "payment-service" successfully rolled out
```

---

## Step 5 — Fix Chart

Restore selector:

```yaml
selector:
  matchLabels:
    app: payment
```

Perform upgrade again:

```bash
helm upgrade payment-service .
```

---

# Prevention

## Rule #1

Never template selectors using values likely to change.

Bad:

```yaml
selector:
  matchLabels:
    app: {{ .Values.appName }}
```

If appName changes:

```yaml
payment
```

↓

```yaml
payment-v2
```

Upgrade fails.

---

## Rule #2

Keep Selectors Stable

Good:

```yaml
selector:
  matchLabels:
    app: payment
```

Use version labels separately:

```yaml
labels:
  version: v2
```

---

## Rule #3

Use Helm Diff in CI/CD

Before deployment:

```bash
helm diff upgrade payment-service .
```

Detect immutable changes before production.

---

## Rule #4

Run Dry Runs

```bash
helm upgrade payment-service . \
  --dry-run
```

---

## Rule #5

Review Immutable Resources During PR

Checklist:

```text
Deployment Selector
Service ClusterIP
PVC Configuration
StatefulSet Volume Claims
```

Any change should trigger review.

---

# Summary

## What Happened?

```text
Helm Upgrade
      │
      ▼
Selector Changed

app=payment
      │
      ▼
app=payment-v2
      │
      ▼
Kubernetes Validation
      │
      ▼
Rejected
      │
      ▼
UPGRADE FAILED
```

---

## Root Cause

The Helm chart modified:

```yaml
spec.selector.matchLabels
```

which is an immutable field.

Kubernetes blocks updates to immutable fields because they define ownership relationships between Deployments, ReplicaSets, and Pods.

---

## Immediate Fix

Restore the original selector:

```yaml
selector:
  matchLabels:
    app: payment
```

Then rerun:

```bash
helm upgrade payment-service .
```

---

## Long-Term Fix

* Never change Deployment selectors
* Use stable labels for selectors
* Add version labels separately
* Use Helm Diff in CI/CD
* Perform dry-run validation
* Use Blue/Green deployments when selectors must change

---

# How Kubernetes Handles Deployment Selectors

```text
Deployment
     │
     ▼
Selector
app=payment
     │
     ▼
ReplicaSet
     │
     ▼
Pods
```

The selector is the permanent ownership link.

Changing it would break resource tracking.

Therefore Kubernetes enforces:

```text
spec.selector
      =
IMMUTABLE
```

---

# Interview Answer

> "The Helm upgrade failed because the Deployment selector changed from `app=payment` to `app=payment-v2`. Kubernetes treats `spec.selector` as an immutable field because it defines which ReplicaSets and Pods belong to the Deployment. Allowing that change could break ownership tracking, so the API server rejects the update. The safest solution is to keep selectors stable and only change pod template labels or version labels. If a selector change is absolutely required, I would use a Blue/Green deployment strategy or recreate the Deployment during a planned maintenance window. In production, I would also use `helm diff` and `helm upgrade --dry-run` in CI/CD to catch immutable field changes before deployment."

---

# Commands Cheat Sheet

```bash
# Render chart
helm template payment-service .

# Preview upgrade
helm diff upgrade payment-service .

# Dry run
helm upgrade payment-service . --dry-run

# View deployment
kubectl get deploy payment-service -o yaml

# Check rollout
kubectl rollout status deployment/payment-service

# View Helm history
helm history payment-service

# Rollback
helm rollback payment-service 1

# Upgrade
helm upgrade payment-service .

# List releases
helm list -A
```
