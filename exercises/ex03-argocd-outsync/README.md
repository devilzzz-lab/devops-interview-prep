# Exercise 1 — ArgoCD Git Deployment Drift

## Incident

Deployment in Git says `replicas: 3` but the live cluster is running `replicas: 5`.

```diff
===== apps/Deployment payment-service ======
< replicas: 3
> replicas: 5
```

Command used:

```bash
argocd app diff payment-service
```

**Status:** `OutOfSync` but `Healthy`

---

# Architecture (intended)

```text
Git Repository
│
└── deployment.yaml
      replicas: 3
            │
            ▼
         ArgoCD
            │
            ▼
 Kubernetes Deployment
            │
            ▼
          3 Pods
```

---

# Architecture (broken — what's actually happening)

```text
Git Repository
│
└── deployment.yaml
      replicas: 3
            │
            ▼
         ArgoCD
            │
            ▼
 Kubernetes Deployment
      replicas: 5
            │
            ▼
          5 Pods

Status: OutOfSync
Reason: Git ≠ Cluster
```

---

# Visual Drift Comparison

```text
Git (Desired State)              Cluster (Actual State)

replicas: 3                      replicas: 5
     │                                │
     └──────────── Drift ─────────────┘

Result:
OutOfSync = TRUE
Healthy   = TRUE
```

---

# Root Cause Analysis

## Q1 — What changed?

Someone manually scaled the deployment in the cluster without committing the change to Git.

ArgoCD continuously compares Git state with cluster state. Since Git says `3` replicas and the cluster has `5`, ArgoCD marks the application as `OutOfSync`.

### Why is Health still Healthy?

Because the application is functioning correctly.

All 5 pods are running and available.

```text
Health Status → Application Health
Sync Status   → Git vs Cluster State
```

An application can be:

```text
Healthy + Synced
Healthy + OutOfSync
Unhealthy + Synced
Unhealthy + OutOfSync
```

In this case:

```text
Healthy + OutOfSync
```

---

## Q2 — Who changed it?

### Check 1 — Kubernetes Events

```bash
kubectl get events -n default --sort-by='.lastTimestamp' | grep payment-service
```

---

### Check 2 — Scaling Events

```bash
kubectl get events -n default -o json | jq '.items[] | select(.reason=="ScalingReplicaSet") | {time: .lastTimestamp, message: .message}'
```

Expected output:

```json
{
  "time": "2026-05-10T07:45:00Z",
  "message": "Scaled up replica set payment-service-abc123 to 5"
}
```

---

### Check 3 — ArgoCD Application History

```bash
argocd app history payment-service
```

Expected output:

```text
ID  DATE                          REVISION
0   2026-05-10 07:00:00 +0000     main (a1b2c3d)
1   2026-05-10 07:45:00 +0000     OutOfSync detected
```

---

### Check 4 — Kubernetes Audit Logs / CloudTrail

If audit logging is enabled:

```bash
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=update \
  --start-time 2026-05-10T07:00:00 \
  --end-time 2026-05-10T08:00:00
```

Look for the IAM user or role that modified the deployment.

---

# Fix — Step by Step

## Option A — Enforce Git as the Source of Truth

Sync ArgoCD back to Git.

```bash
argocd app sync payment-service
```

Expected output:

```text
TIMESTAMP                 GROUP   KIND        NAMESPACE NAME             STATUS  HEALTH
2026-05-10T08:15:00      apps    Deployment  default   payment-service  Synced  Healthy
```

Verify:

```bash
kubectl get deploy payment-service
```

Expected output:

```text
NAME              READY   UP-TO-DATE   AVAILABLE
payment-service   3/3     3            3
```

---

## Option B — Update Git (If Scaling Was Intentional)

Modify the deployment manifest:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-service
spec:
  replicas: 5
```

Commit and push:

```bash
git add deployment.yaml
git commit -m "scale payment-service to 5 replicas"
git push
```

ArgoCD will detect the new desired state and sync automatically if Auto-Sync is enabled.

---

# Prevent Recurrence

## Enable ArgoCD Self-Heal

Self-Heal automatically reverts manual changes.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: payment-service
spec:
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

Apply:

```bash
kubectl apply -f argocd-app.yaml -n argocd
```

Or:

```bash
argocd app set payment-service --self-heal
```

After enabling Self-Heal:

```text
kubectl scale deployment payment-service --replicas=5
                │
                ▼
          ArgoCD detects drift
                │
                ▼
      Deployment reverted to 3
```

---

## Restrict Manual Scaling with RBAC

Create a read-only role:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: read-only
  namespace: default
rules:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs:
      - get
      - list
      - watch
```

Apply:

```bash
kubectl apply -f read-only-role.yaml
```

Create RoleBinding:

```bash
kubectl create rolebinding dev-read-only \
  --role=read-only \
  --user=dev-user \
  --namespace=default
```

Verify:

```bash
kubectl describe role read-only -n default
kubectl describe rolebinding dev-read-only -n default
```

---

## Configure Drift Alerts

Example notification trigger:

```yaml
triggers:
  - name: on-out-of-sync
    condition: app.status.sync.status == 'OutOfSync'
    template: out-of-sync-alert

templates:
  - name: out-of-sync-alert
    message: |
      App {{ .app.metadata.name }} is OutOfSync.
      Sync Status: {{ .app.status.sync.status }}
```

Example alert:

```text
Application: payment-service
Status: OutOfSync
Action Required: Investigate Drift
```

---

# Summary

## What Happened?

```text
Developer/Admin
      │
      ▼
kubectl scale deployment payment-service --replicas=5
      │
      ▼
Cluster State Changed
      │
      ▼
Git Still Says replicas=3
      │
      ▼
ArgoCD Detects Drift
      │
      ▼
OutOfSync
```

---

## Immediate Fix

Choose one:

### Revert cluster to Git

```bash
argocd app sync payment-service
```

### Update Git to match cluster

```bash
git commit
git push
```

---

## Long-Term Fixes

* Enable ArgoCD Self-Heal
* Enable Auto-Sync
* Restrict kubectl access with RBAC
* Configure OutOfSync notifications
* Enable Kubernetes audit logging

---

# How ArgoCD Sync Works Internally

```text
Git Repository
      │
      ▼
Desired State
      │
      ▼
ArgoCD Controller
      │
      ▼
Compare Desired vs Actual
      │
      ├── Match
      │      ▼
      │   Synced
      │
      └── Different
             ▼
         OutOfSync
             │
             ▼
     selfHeal: true ?
             │
       ┌─────┴─────┐
       │           │
      Yes         No
       │           │
       ▼           ▼
 Auto Revert    Alert Only
```

Key Principle:

```text
Git = Source of Truth
Cluster = Desired State Applied From Git
```

---

# Interview Answer

> "The application was OutOfSync because the deployment was manually scaled in the cluster from 3 replicas to 5 replicas without updating Git. ArgoCD detected the difference between the desired state in Git and the actual state in Kubernetes. Health remained Healthy because all pods were running successfully. To investigate, I would check Kubernetes events, ArgoCD application history, and audit logs to identify who modified the deployment. The immediate fix would be either running `argocd app sync` to restore the Git state or updating Git if the scaling change was intentional. To prevent recurrence, I would enable ArgoCD Self-Heal, enforce GitOps practices, restrict direct deployment updates through RBAC, and configure drift alerts."

---

# Commands Cheat Sheet

```bash
# Check drift
argocd app diff payment-service

# View sync history
argocd app history payment-service

# Check deployment
kubectl get deploy payment-service

# Sync Git -> Cluster
argocd app sync payment-service

# Enable self-heal
argocd app set payment-service --self-heal

# Verify application status
kubectl get application payment-service -n argocd

# Kubernetes events
kubectl get events -n default --sort-by='.lastTimestamp' | grep payment-service

# RBAC verification
kubectl describe role read-only -n default
kubectl describe rolebinding dev-read-only -n default
```
