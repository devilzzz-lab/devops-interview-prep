# Exercise 22: Horizontal and Cluster Autoscaling

> Configure Kubernetes Horizontal Pod Autoscaler (HPA) and demonstrate automatic pod scaling under load. Understand how Cluster Autoscaler works when nodes become insufficient.

---

## Objectives

Implement:

* Horizontal Pod Autoscaler (HPA)
* Metrics Server
* Load Testing
* Cluster Autoscaler Concepts

Expected Outcome:

```text
Pods: 2 → 20
Nodes: 3 → 6 (real cloud environments)
```

---

## Prerequisites

Verify cluster:

```bash
kubectl cluster-info
kubectl get nodes
```

Expected:

```text
NAME                         STATUS
kind-control-plane           Ready
kind-worker                  Ready
kind-worker2                 Ready
```

---

## Step 1 — Install Metrics Server

HPA requires metrics.

Install:

```bash
kubectl apply -f \
https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

Patch for KIND:

```bash
kubectl patch deployment metrics-server \
-n kube-system \
--type='json' \
-p='[
{
 "op":"add",
 "path":"/spec/template/spec/containers/0/args/-",
 "value":"--kubelet-insecure-tls"
}
]'
```

Verify:

```bash
kubectl get pods -n kube-system
```

Expected:

```text
metrics-server-xxxxx   1/1 Running
```

---

## Step 2 — Verify Metrics

Wait 1–2 minutes.

Check:

```bash
kubectl top nodes
```

Expected:

```text
NAME                 CPU(cores)   MEMORY(bytes)
kind-control-plane   150m         900Mi
kind-worker          80m          600Mi
kind-worker2         95m          650Mi
```

Check pods:

```bash
kubectl top pods -A
```

Metrics should be visible.

---

## Step 3 — Create Namespace

```bash
kubectl create namespace autoscaling
```

---

## Step 4 — Create Deployment

Create working directory:

```bash
mkdir -p exercises/ex22-autoscaling
cd exercises/ex22-autoscaling
```

### deployment.yaml

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: autoscale-app
  namespace: autoscaling
spec:
  replicas: 2
  selector:
    matchLabels:
      app: autoscale-app
  template:
    metadata:
      labels:
        app: autoscale-app
    spec:
      containers:
        - name: nginx
          image: nginx:latest
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: autoscale-app
  namespace: autoscaling
spec:
  selector:
    app: autoscale-app
  ports:
    - port: 80
      targetPort: 80
  type: ClusterIP
```

Apply:

```bash
kubectl apply -f deployment.yaml
```

Verify:

```bash
kubectl get pods -n autoscaling
```

Expected:

```text
autoscale-app-xxxxx   Running
autoscale-app-yyyyy   Running
```

---

## Step 5 — Create HPA

### hpa.yaml

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: autoscale-app
  namespace: autoscaling
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: autoscale-app

  minReplicas: 2
  maxReplicas: 20

  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 50
```

Apply:

```bash
kubectl apply -f hpa.yaml
```

Verify:

```bash
kubectl get hpa -n autoscaling
```

Expected:

```text
NAME            REFERENCE                  TARGETS
autoscale-app   Deployment/autoscale-app   0%/50%
```

---

## Step 6 — Expose Service

Port forward:

```bash
kubectl port-forward svc/autoscale-app \
-n autoscaling 8080:80
```

Test:

```bash
curl http://localhost:8080
```

Expected:

```html
Welcome to nginx!
```

---

## Step 7 — Install Load Generator

### hey

```bash
brew install hey
```

Verify:

```bash
hey -version
```

---

### Apache Bench

```bash
brew install httpd
```

Verify:

```bash
ab -V
```

---

### k6

```bash
brew install k6
```

Verify:

```bash
k6 version
```

---

## Step 8 — Generate Load

### Using hey

```bash
hey -z 5m -c 200 http://localhost:8080
```

Meaning:

```text
-z 5m = run for 5 minutes
-c 200 = 200 concurrent users
```

---

## Step 9 — Watch HPA

```bash
kubectl get hpa -n autoscaling -w
```

Expected:

```text
NAME            REFERENCE                  TARGETS
autoscale-app   Deployment/autoscale-app   65%/50%
autoscale-app   Deployment/autoscale-app   110%/50%
autoscale-app   Deployment/autoscale-app   150%/50%
```

---

## Step 10 — Watch Pod Scaling

```bash
kubectl get pods -n autoscaling -w
```

Expected:

```text
2 Pods
4 Pods
8 Pods
12 Pods
16 Pods
20 Pods
```

Verify:

```bash
kubectl get deploy -n autoscaling
```

Expected:

```text
NAME            READY
autoscale-app   20/20
```

---

## Step 11 — Check HPA Details

```bash
kubectl describe hpa autoscale-app \
-n autoscaling
```

Expected:

```text
Min replicas: 2
Max replicas: 20

Current CPU: 145%
Target CPU: 50%
```

---

## Step 12 — Stop Load

Press:

```text
CTRL + C
```

Wait 3–5 minutes.

Watch:

```bash
kubectl get hpa -n autoscaling -w
```

Expected:

```text
20
15
10
5
2
```

---

## Step 13 — Verify Scale Down

```bash
kubectl get deploy -n autoscaling
```

Expected:

```text
NAME            READY
autoscale-app   2/2
```

HPA successfully scaled down.

---

# Cluster Autoscaler Concept

HPA only creates pods.

If there are not enough resources:

```text
Pending Pods
```

appear.

Example:

```bash
kubectl get pods
```

```text
autoscale-app-xyz   Pending
```

Reason:

```bash
kubectl describe pod <pod-name>
```

Expected:

```text
0/3 nodes available:
Insufficient cpu
```

---

# How Cluster Autoscaler Solves This

In EKS:

```text
Current Nodes = 3
```

HPA creates:

```text
20 Pods
```

Cluster lacks CPU.

Cluster Autoscaler detects:

```text
Pending Pods
```

and automatically provisions:

```text
Node 4
Node 5
Node 6
```

Result:

```text
Pods = 20
Nodes = 6
```

No manual action required.

---

# Verify Autoscaling Components

HPA:

```bash
kubectl get hpa -A
```

Metrics:

```bash
kubectl top nodes
```

Deployment:

```bash
kubectl get deploy -n autoscaling
```

Pods:

```bash
kubectl get pods -n autoscaling
```

---

# Interview Questions

| Component          | Purpose                     |
| ------------------ | --------------------------- |
| Metrics Server     | Provides CPU/Memory metrics |
| HPA                | Scales Pods                 |
| Cluster Autoscaler | Scales Nodes                |
| VPA                | Adjusts CPU/Memory requests |
| KEDA               | Event-based autoscaling     |

---

# Interview Answer

"I implemented Horizontal Pod Autoscaling using Metrics Server and Kubernetes HPA. The deployment started with 2 replicas and was configured with a minimum of 2 and maximum of 20 replicas. HPA monitored CPU utilization and automatically scaled the application when CPU usage exceeded 50%. I generated load using hey and observed pods scaling from 2 to 20 replicas. After the load stopped, HPA gradually scaled the deployment back down to 2 replicas. In cloud environments like EKS, if HPA creates more pods than the current nodes can support, Cluster Autoscaler detects pending pods and automatically provisions additional worker nodes, for example scaling the cluster from 3 nodes to 6 nodes."
