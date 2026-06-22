# Exercise 18: GitOps Platform with ArgoCD

> Set up a fully declarative GitOps deployment pipeline using ArgoCD with three environments — dev, qa, and prod — each auto-synced from a Git repository.

---

## What you need installed

```bash
# Install ArgoCD CLI
brew install argocd

# Verify
argocd version --client
```

---

## Step 1 — Create the folder structure

```bash
cd exercises/ex18-gitops-argocd
```

---

## Step 2 — Write deployment manifests for each env

### gitops/dev/deployment.yaml

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-service
  namespace: dev
spec:
  replicas: 1
  selector:
    matchLabels:
      app: payment-service
  template:
    metadata:
      labels:
        app: payment-service
    spec:
      containers:
        - name: payment-service
          image: nginx:latest
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
---
apiVersion: v1
kind: Service
metadata:
  name: payment-service
  namespace: dev
spec:
  selector:
    app: payment-service
  ports:
    - port: 80
      targetPort: 80
  type: ClusterIP
```

### gitops/qa/deployment.yaml

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-service
  namespace: qa
spec:
  replicas: 2
  selector:
    matchLabels:
      app: payment-service
  template:
    metadata:
      labels:
        app: payment-service
    spec:
      containers:
        - name: payment-service
          image: nginx:latest
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 200m
              memory: 256Mi
            limits:
              cpu: 500m
              memory: 512Mi
---
apiVersion: v1
kind: Service
metadata:
  name: payment-service
  namespace: qa
spec:
  selector:
    app: payment-service
  ports:
    - port: 80
      targetPort: 80
  type: ClusterIP
```

### gitops/prod/deployment.yaml

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-service
  namespace: prod
spec:
  replicas: 5
  selector:
    matchLabels:
      app: payment-service
  template:
    metadata:
      labels:
        app: payment-service
    spec:
      containers:
        - name: payment-service
          image: nginx:latest
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 500m
              memory: 512Mi
            limits:
              cpu: "2"
              memory: 2Gi
---
apiVersion: v1
kind: Service
metadata:
  name: payment-service
  namespace: prod
spec:
  selector:
    app: payment-service
  ports:
    - port: 80
      targetPort: 80
  type: ClusterIP
```

---

## Step 3 — Commit and push

```bash
git add .
git commit -m "ex18: add gitops manifests for dev, qa, prod"
git push origin main
```

Expected:

```text
main -> main
```

---

## Step 4 — Install ArgoCD on kind cluster

```bash
# Switch to kind cluster
kubectl config use-context kind-debug-cluster

# Create argocd namespace
kubectl create namespace argocd

# Install ArgoCD
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

Wait for all pods to come up:

```bash
kubectl get pods -n argocd -w
```

Expected (all Running):

```text
NAME                                       READY   STATUS
argocd-application-controller-0            1/1     Running
argocd-dex-server-xxxxxxxxx                1/1     Running
argocd-redis-xxxxxxxxx                     1/1     Running
argocd-repo-server-xxxxxxxxx               1/1     Running
argocd-server-xxxxxxxxx                    1/1     Running
```

---

## Step 5 — Access ArgoCD UI

```bash
# Port forward ArgoCD server
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Open browser:

```text
https://localhost:8080
```

Get the initial admin password:

```bash
kubectl get secret argocd-initial-admin-secret \
  -n argocd \
  -o jsonpath='{.data.password}' | base64 -d
```

Login:

```text
Username: admin
Password: output from above command
```

---

## Step 6 — Login via CLI

```bash
argocd login localhost:8080 \
  --username admin \
  --password <paste-password-here> \
  --insecure
```

Expected:

```text
'admin:login' logged in successfully
```

---

## Step 7 — Create namespaces on cluster

```bash
kubectl create namespace dev
kubectl create namespace qa
kubectl create namespace prod
```

---

## Step 8 — Create ArgoCD apps (one per env)

### Dev app

```bash
argocd app create payment-service-dev \
  --repo https://github.com/<your-username>/<your-repo>.git \
  --path exercises/ex18-gitops-argocd/gitops/dev \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace dev \
  --sync-policy automated \
  --auto-prune \
  --self-heal
```

### QA app

```bash
argocd app create payment-service-qa \
  --repo https://github.com/<your-username>/<your-repo>.git \
  --path exercises/ex18-gitops-argocd/gitops/qa \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace qa \
  --sync-policy automated \
  --auto-prune \
  --self-heal
```

### Prod app

```bash
argocd app create payment-service-prod \
  --repo https://github.com/<your-username>/<your-repo>.git \
  --path exercises/ex18-gitops-argocd/gitops/prod \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace prod \
  --sync-policy automated \
  --auto-prune \
  --self-heal
```

---

## Step 9 — Verify all apps are synced

```bash
argocd app list
```

Expected:

```text
NAME                    CLUSTER     NAMESPACE  PROJECT  STATUS  HEALTH
payment-service-dev     in-cluster  dev        default  Synced  Healthy
payment-service-qa      in-cluster  qa         default  Synced  Healthy
payment-service-prod    in-cluster  prod       default  Synced  Healthy
```

```bash
kubectl get pods -n dev
kubectl get pods -n qa
kubectl get pods -n prod
```

Expected:

```text
# dev
NAME                               READY   STATUS
payment-service-xxxxxxx            1/1     Running

# qa
NAME                               READY   STATUS
payment-service-xxxxxxx            1/1     Running
payment-service-yyyyyyy            1/1     Running

# prod
NAME                               READY   STATUS
payment-service-xxxxxxx            1/1     Running
... (5 pods)
```

---

## Step 10 — Test Auto Sync (the GitOps part)

Change replicas in dev from 1 to 3:

```bash
# Edit exercises/ex18-gitops-argocd/gitops/dev/deployment.yaml
# Change replicas: 1 → replicas: 3

git add exercises/ex18-gitops-argocd/gitops/dev/deployment.yaml
git commit -m "ex18: scale dev to 3 replicas"
git push origin main
```

Wait ~3 minutes (ArgoCD polls every 3 min) or force sync now:

```bash
argocd app sync payment-service-dev
```

Verify:

```bash
kubectl get deploy -n dev
```

Expected:

```text
NAME              READY   UP-TO-DATE   AVAILABLE
payment-service   3/3     3            3
```

---

## Step 11 — Test Self-Heal

This proves ArgoCD reverts manual changes:

```bash
# Manually scale dev to 10 — this should get reverted
kubectl scale deploy payment-service -n dev --replicas=10

# Check immediately
kubectl get deploy -n dev
```

Wait 30–60 seconds, then check again:

```bash
kubectl get deploy -n dev
```

Expected — back to 3 (whatever Git says):

```text
NAME              READY   UP-TO-DATE   AVAILABLE
payment-service   3/3     3            3
```

Self-heal worked! ArgoCD detected the drift and reverted it.

---

## Step 12 — Test Pruning

Add a new resource to Git, then remove it — pruning deletes it from the cluster:

```bash
# Create a test configmap
cat > exercises/ex18-gitops-argocd/gitops/dev/configmap.yaml << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: test-config
  namespace: dev
data:
  key: value
EOF

git add . && git commit -m "ex18: add test configmap" && git push
argocd app sync payment-service-dev

# Verify it was created
kubectl get configmap -n dev
```

Now remove it from Git:

```bash
rm exercises/ex18-gitops-argocd/gitops/dev/configmap.yaml
git add . && git commit -m "ex18: remove test configmap" && git push
argocd app sync payment-service-dev

# Verify it was deleted from cluster too
kubectl get configmap -n dev
```

Expected — test-config is gone. That is pruning working.

---

## Key concepts to explain in interview

| Feature                                  | What it does                                              |
| ---------------------------------------- | --------------------------------------------------------- |
| `--sync-policy automated`                | ArgoCD polls Git every 3 min and syncs automatically      |
| `--self-heal`                            | Any manual kubectl change gets reverted back to Git state |
| `--auto-prune`                           | Resources deleted from Git get deleted from cluster too   |
| `gitops/dev`, `gitops/qa`, `gitops/prod` | Each folder = one environment, one ArgoCD app             |

---

## Interview answer (say this)

"I set up a GitOps platform using ArgoCD with three ArgoCD Applications — one each for dev, qa, and prod — each pointing to a different folder in the same Git repository. Auto-sync means ArgoCD polls Git every 3 minutes and applies any changes automatically — no manual kubectl apply needed. Self-heal means if anyone manually changes something in the cluster, ArgoCD detects the drift and reverts it back to what Git says — Git is always the source of truth. Pruning means if I delete a manifest from Git, ArgoCD also deletes that resource from the cluster. This gives us a fully declarative, auditable deployment pipeline — every change is a Git commit."