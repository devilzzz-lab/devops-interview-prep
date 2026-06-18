# Exercise 6 — EKS Node Scale Failure

## Objective

Diagnose why an application cannot scale even though the Horizontal Pod Autoscaler (HPA) is requesting additional replicas.

---

## Symptoms

### HPA Status

```text
Desired Replicas: 15
Current Replicas: 5
```

### Pending Pods

```text
0/3 nodes available:
Insufficient CPU
```

### Cluster Autoscaler Logs

```text
No node group config found
```

---

## Architecture

```text
Application
     ↓
Deployment
     ↓
HPA
     ↓
Additional Pods Created
     ↓
Scheduler
     ↓
Available Nodes?
     ↓
Cluster Autoscaler
     ↓
EKS Node Group
```

Scaling flow:

```text
High CPU Usage
      ↓
HPA increases replicas
      ↓
New Pods created
      ↓
Scheduler tries to place Pods
      ↓
No CPU available
      ↓
Cluster Autoscaler should add nodes
      ↓
New nodes join cluster
      ↓
Pods become Running
```

---

## Step 1 — Verify HPA Status

Check the HPA:

```bash
kubectl get hpa
```

Expected:

```text
NAME      REFERENCE             TARGETS   MINPODS   MAXPODS   REPLICAS
web-app   Deployment/web-app    90%/50%   2         20        15
```

Describe the HPA:

```bash
kubectl describe hpa web-app
```

Expected:

```text
Desired Replicas: 15
Current Replicas: 5
```

### What this tells us

The HPA is functioning correctly.

```text
CPU usage increased
      ↓
HPA calculated desired replicas
      ↓
HPA requested 15 replicas
```

The HPA is not the problem.

---

## Step 2 — Check Deployment Status

```bash
kubectl get deployment
```

Expected:

```text
NAME      READY   UP-TO-DATE   AVAILABLE
web-app   5/15    15           5
```

Check Pods:

```bash
kubectl get pods
```

Expected:

```text
Running Pods: 5
Pending Pods: 10
```

This means Kubernetes created the Pods but cannot schedule them.

---

## Step 3 — Inspect Pending Pods

Describe one Pending Pod:

```bash
kubectl describe pod <pending-pod>
```

Expected:

```text
Events:

0/3 nodes available:
Insufficient CPU
```

### Interpretation

The scheduler attempted to place the Pod but every node lacks sufficient CPU resources.

```text
Pod Created
      ↓
Scheduler Attempt
      ↓
No Node Has Free CPU
      ↓
Pod Remains Pending
```

---

## Step 4 — Check Node Resources

View node utilization:

```bash
kubectl top nodes
```

Example:

```text
NAME       CPU(cores)   CPU%
node-1     3900m        98%
node-2     3950m        99%
node-3     3980m        99%
```

Check allocatable resources:

```bash
kubectl describe node
```

Look for:

```text
Allocated resources:
CPU Requests close to 100%
```

### What this tells us

The cluster is out of available CPU capacity.

---

## Step 5 — Check Cluster Autoscaler

Find Autoscaler Pod:

```bash
kubectl get pods -n kube-system | grep autoscaler
```

Example:

```text
cluster-autoscaler-abc123
```

View logs:

```bash
kubectl logs -n kube-system cluster-autoscaler-abc123
```

Expected:

```text
No node group config found
```

### Interpretation

Cluster Autoscaler cannot identify any EKS Node Group to scale.

```text
Pending Pods Detected
        ↓
Autoscaler Triggered
        ↓
No Node Group Found
        ↓
Cannot Launch New Nodes
```

---

## Step 6 — Verify EKS Node Group Configuration

Typical checks:

```bash
kubectl describe deployment cluster-autoscaler -n kube-system
```

Look for:

```text
--node-group-auto-discovery
```

Example:

```text
--node-group-auto-discovery=asg:tag=k8s.io/cluster-autoscaler/enabled
```

Verify EKS Managed Node Groups have required tags:

```text
k8s.io/cluster-autoscaler/enabled=true

k8s.io/cluster-autoscaler/<cluster-name>=owned
```

Missing tags can prevent discovery.

---

## Root Cause Analysis

### HPA Issue?

NO ❌

Evidence:

```text
Desired Replicas: 15
Current Replicas: 5
```

HPA successfully calculated and requested additional replicas.

The HPA is working correctly.

---

### Node Issue?

YES ✅

Evidence:

```text
0/3 nodes available:
Insufficient CPU
```

The existing nodes have no remaining CPU capacity.

Pods cannot be scheduled.

---

### Autoscaler Issue?

YES ✅

Evidence:

```text
No node group config found
```

Cluster Autoscaler cannot identify a node group to scale.

No new nodes can be added.

---

## Verification Commands Summary

```bash
kubectl get hpa

kubectl describe hpa

kubectl get deployment

kubectl get pods

kubectl describe pod <pending-pod>

kubectl top nodes

kubectl describe node

kubectl get pods -n kube-system | grep autoscaler

kubectl logs -n kube-system <cluster-autoscaler-pod>

kubectl describe deployment cluster-autoscaler -n kube-system
```

---

## Troubleshooting Flow

```text
Application Cannot Scale
           ↓
Check HPA
           ↓
Desired > Current ?
           ↓
Check Pending Pods
           ↓
Insufficient CPU ?
           ↓
Check Node Resources
           ↓
Nodes Full ?
           ↓
Check Cluster Autoscaler
           ↓
Node Group Found ?
           ↓
Identify Root Cause
```

---

## Common Autoscaler Errors

| Error                      | Root Cause                   |
| -------------------------- | ---------------------------- |
| No node group config found | Node Group Discovery Failure |
| Failed to scale up         | IAM Permission Issue         |
| No expansion options       | Node Group Max Size Reached  |
| Insufficient CPU           | Cluster Capacity Exhausted   |
| Insufficient Memory        | Cluster Capacity Exhausted   |
| HPA Desired > Current      | Scheduler or Node Issue      |
| HPA Not Scaling            | Metrics/HPA Issue            |

---

## Final Diagnosis

```text
HPA Issue: NO

Node Issue: YES

Autoscaler Issue: YES

Root Cause:

Existing nodes have no available CPU.

Cluster Autoscaler cannot discover
a valid EKS Node Group and therefore
cannot launch additional nodes.
```

---

## Interview Answer

> "I would first check the HPA and verify that it is calculating the desired replica count correctly. Since the HPA wants 15 replicas, it is functioning properly. Next I would inspect the Pending Pods and identify the scheduling failure. The events show Insufficient CPU, which means the existing nodes are exhausted. Then I would check the Cluster Autoscaler logs. The message 'No node group config found' indicates the autoscaler cannot discover or manage any EKS node group. Therefore the HPA is healthy, the nodes are out of capacity, and the primary root cause is a Cluster Autoscaler configuration issue preventing new nodes from being created."
