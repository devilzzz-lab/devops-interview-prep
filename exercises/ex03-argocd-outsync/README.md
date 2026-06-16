# Exercise 1 — ArgoCD Git Deployment Drift

## Incident

Deployment in Git says `replicas: 3` but live cluster is running `replicas: 5`.
===== apps/Deployment payment-service ======
8c8 < replicas: 3

replicas: 5


Command used:
```bash
argocd app diff payment-service
```

**Status:** `OutOfSync` but `Healthy`

---

## Architecture (intended)
Git Repository
└── deployment.yaml (replicas: 3)
└── ArgoCD (syncs Git to cluster)
└── Kubernetes Deployment
└── 3 Pods


## Architecture (broken — what's actually happening)
Git Repository
└── deployment.yaml (replicas: 3)
└── ArgoCD (detects drift)
└── Kubernetes Deployment
└── 5 Pods ← Manually scaled via kubectl
└── OutOfSync (Git ≠ cluster)


---

## Root Cause Analysis

### Q1 — What changed?

Someone **manually scaled** the deployment in the cluster without committing the change to Git. ArgoCD noticed the drift and flagged `OutOfSync`.

**Why is Health still Healthy?** Because the pods are actually running fine — 5 replicas are up. `OutOfSync` is about Git vs cluster mismatch, not about whether the app is broken.

---

### Q2 — Who changed it?

Check these in order:

#### Check 1 — Kubernetes events

```bash
kubectl get events -n default --sort-by='.lastTimestamp' | grep payment-service
```

#### Check 2 — Scaling replica set events

```bash
# If audit logging is enabled on the cluster
kubectl get events -n default -o json | jq '.items[] | select(.reason=="ScalingReplicaSet") | {time: .lastTimestamp, message: .message}'
```

Expected output:
```json
{
  "time": "2026-05-10T07:45:00Z",
  "message": "Scaled up replica set payment-service-abc123 to 5"
}
```

#### Check 3 — ArgoCD app history

```bash
argocd app history payment-service
```

Expected output:
ID DATE REVISION
0 2026-05-10 07:00:00 +0000 main (a1b2c3d)
1 2026-05-10 07:45:00 +0000 OutOfSync detected


#### Check 4 — CloudTrail audit logs (if enabled)

```bash
# Look for who called kubectl scale
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=update \
  --start-time 2026-05-10T07:00:00 \
  --end-time 2026-05-10T08:00:00
```

---

## Fix — Step by Step

### Option A — Sync Git back to cluster (enforce Git as truth)

This will scale the cluster back down to 3:

```bash
argocd app sync payment-service
```

Expected output:
TIMESTAMP GROUP KIND NAMESPACE NAME STATUS HEALTH HOOK MESSAGE
2026-05-10T08:15:00 apps Deployment default payment-service Synced Healthy deployment.apps/payment-service configured


**Verify:**
```bash
kubectl get deploy payment-service
```

Expected output:
NAME READY UP-TO-DATE AVAILABLE
payment-service 3/3 3 3


---

### Option B — Update Git to match cluster (if 5 replicas was intentional)

Update `deployment.yaml` in Git:
```yaml
# deployment.yaml in Git
replicas: 5   # update this
```

```bash
git add deployment.yaml
git commit -m "scale payment-service to 5 replicas"
git push
```

ArgoCD will detect the Git change and auto-sync if Auto-Sync is enabled.

---

### Step 3: Enable ArgoCD Self-Heal (prevent recurrence)

Self-Heal makes ArgoCD automatically revert any manual changes back to Git state:

Save as `argocd-app.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: payment-service
spec:
  syncPolicy:
    automated:
      prune: true       # delete resources removed from Git
      selfHeal: true    # revert manual changes in cluster ← this prevents drift
```

Apply:
```bash
kubectl apply -f argocd-app.yaml -n argocd
```

**Or via CLI:**
```bash
argocd app set payment-service --self-heal
```

After this, if anyone runs `kubectl scale` manually → ArgoCD detects it within seconds and reverts it back to Git.

---

### Step 4: Lock down kubectl access with RBAC

Prevent manual scaling via Kubernetes RBAC. Remove `update` permission on deployments for non-admins:

Save as `read-only-role.yaml`:
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: read-only
  namespace: default
rules:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "watch"]   # no update, no patch, no delete
```

Apply:
```bash
kubectl apply -f read-only-role.yaml
kubectl create rolebinding dev-read-only \
  --role=read-only \
  --user=dev-user \
  --namespace=default
```

---

### Step 5: Set up drift alert in ArgoCD

Add a notification so the team gets alerted immediately when OutOfSync happens:

Save as `argocd-notifications-cm.yaml`:
```yaml
# argocd-notifications-cm (ConfigMap)
triggers:
  - name: on-out-of-sync
    condition: app.status.sync.status == 'OutOfSync'
    template: out-of-sync-alert

templates:
  - name: out-of-sync-alert
    message: |
      App {{ .app.metadata.name }} is OutOfSync.
      Sync status: {{ .app.status.sync.status }}
```

---

### Summary — What happened and how to fix
Root Cause: Manual kubectl scale → Git ≠ cluster → OutOfSync
Immediate Fix: argocd app sync (enforce Git) OR update Git (if intentional)
Long-term: Enable selfHeal + RBAC + drift alerts

---

## How ArgoCD Sync Works Internally

When ArgoCD is correctly configured:

1. ArgoCD continuously compares Git state vs cluster state
2. If mismatch detected → status becomes `OutOfSync`
3. If `selfHeal: true` → automatically reverts cluster to match Git
4. If `autoSync: true` → automatically syncs when Git changes
5. Health status is independent → app can be `Healthy` but `OutOfSync`

The key principle: **Git is the source of truth**.

---

## Interview Answer (say this)

"The OutOfSync happened because someone manually ran `kubectl scale` on the live cluster without updating Git. ArgoCD detected the drift — Git said 3 replicas, cluster had 5. Health was still Healthy because pods were running fine — OutOfSync and Unhealthy are different things. To find who changed it, I'd check Kubernetes events, ArgoCD app history, and audit logs. The immediate fix is `argocd app sync` to enforce Git as the source of truth. Long-term fix is enabling Self-Heal in ArgoCD's sync policy so any manual change is automatically reverted, plus tightening RBAC to prevent direct `kubectl scale` in production."

---

## Key Commands Cheatsheet

```bash
# Debug ArgoCD drift
argocd app diff payment-service
argocd app history payment-service
kubectl get deploy payment-service

# Fix drift
argocd app sync payment-service
argocd app set payment-service --self-heal

# Verify sync status
kubectl get application payment-service -n argocd

# Check Kubernetes events
kubectl get events -n default --sort-by='.lastTimestamp' | grep payment-service

# RBAC verification
kubectl describe role read-only -n default
kubectl describe rolebinding dev-read-only -n default
```