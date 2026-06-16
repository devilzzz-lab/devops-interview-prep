# Exercise 9 — Prometheus Monitoring Failure (ServiceMonitor Port Mismatch)

## Incident

Metrics suddenly disappeared from Grafana.

### Symptoms

#### Grafana

```text
No Data
```

#### Prometheus Targets

```text
payment-service    DOWN
```

#### Prometheus Logs

```text
context deadline exceeded
```

---

## ServiceMonitor

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: payment-service
spec:
  endpoints:
    - port: metrics
      interval: 30s
```

---

## Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: payment-service
spec:
  ports:
    - name: prometheus
      port: 8080
      targetPort: 8080
```

---

# Architecture (Expected)

```text
Application
     │
     ▼
Metrics Endpoint
     │
     ▼
Service
port name = metrics
     │
     ▼
ServiceMonitor
port = metrics
     │
     ▼
Prometheus
     │
     ▼
Grafana Dashboard
```

---

# Architecture (Broken)

```text
Application
     │
     ▼
Metrics Endpoint
     │
     ▼
Service
port name = prometheus
     │
     ▼
ServiceMonitor
port = metrics
     │
     ▼
Port Not Found
     │
     ▼
Prometheus Target DOWN
     │
     ▼
Grafana No Data
```

---

# Root Cause Analysis

## Q1 — What happened?

The ServiceMonitor is looking for a Service port named:

```yaml
port: metrics
```

However the Service exposes:

```yaml
name: prometheus
```

Prometheus Operator uses the ServiceMonitor's `port` field to locate a Service port by name.

Current state:

```text
ServiceMonitor → metrics

Service → prometheus
```

Mismatch detected.

Prometheus cannot find a matching port.

As a result:

```text
Prometheus
    │
    ▼
Cannot Scrape Metrics
    │
    ▼
Target DOWN
    │
    ▼
Grafana No Data
```

---

## Q2 — Why does Prometheus show "context deadline exceeded"?

Prometheus repeatedly attempts to scrape the endpoint.

Because the configured port cannot be resolved correctly, the scrape fails.

Example:

```text
GET /metrics
```

Prometheus waits for a response.

Eventually:

```text
context deadline exceeded
```

This means the scrape request timed out before receiving a valid response.

---

# Understanding How ServiceMonitor Works

Prometheus Operator follows this flow:

```text
ServiceMonitor
      │
      ▼
Find Matching Service
      │
      ▼
Find Port By Name
      │
      ▼
Discover Endpoint
      │
      ▼
Scrape /metrics
      │
      ▼
Store Metrics
```

The critical detail:

```text
ServiceMonitor.port
must match
Service.ports[].name
```

Not:

```text
ServiceMonitor.port
=
Service.port number
```

It matches the Service port NAME.

---

# Find the Mismatch

## ServiceMonitor

```yaml
endpoints:
  - port: metrics
```

Prometheus expects:

```yaml
ports:
  - name: metrics
```

---

## Actual Service

```yaml
ports:
  - name: prometheus
```

Mismatch:

```diff
ServiceMonitor
- metrics

Service
+ prometheus
```

Root Cause Found.

---

# How to Verify

## Step 1 — Check ServiceMonitor

```bash
kubectl get servicemonitor payment-service -o yaml
```

Expected:

```yaml
endpoints:
  - port: metrics
```

---

## Step 2 — Check Service

```bash
kubectl get svc payment-service -o yaml
```

Expected:

```yaml
ports:
  - name: prometheus
```

---

## Step 3 — Describe Service

```bash
kubectl describe svc payment-service
```

Expected output:

```text
Port: prometheus 8080/TCP
```

---

## Step 4 — Inspect Prometheus Targets

Open:

```text
http://prometheus:9090/targets
```

Expected:

```text
payment-service

State: DOWN
```

Error:

```text
context deadline exceeded
```

---

## Step 5 — Verify Endpoints

```bash
kubectl get endpoints payment-service
```

Expected:

```text
NAME              ENDPOINTS
payment-service   10.1.5.10:8080
```

Endpoints exist.

Problem is not networking.

Problem is configuration mismatch.

---

# Fix Option A (Recommended)

Update ServiceMonitor to match Service.

Current:

```yaml
endpoints:
  - port: metrics
```

Change to:

```yaml
endpoints:
  - port: prometheus
```

Apply:

```bash
kubectl apply -f servicemonitor.yaml
```

---

## Updated ServiceMonitor

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: payment-service
spec:
  selector:
    matchLabels:
      app: payment-service

  endpoints:
    - port: prometheus
      path: /metrics
      interval: 30s
```

---

# Fix Option B

Rename the Service port.

Current:

```yaml
ports:
  - name: prometheus
```

Change to:

```yaml
ports:
  - name: metrics
```

Example:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: payment-service
spec:
  ports:
    - name: metrics
      port: 8080
      targetPort: 8080
```

Apply:

```bash
kubectl apply -f service.yaml
```

---

# Verification After Fix

## Check Prometheus Targets

```text
payment-service

UP
```

---

## Verify Target Status

Open:

```text
Prometheus → Status → Targets
```

Expected:

```text
payment-service

State: UP
```

---

## Query Metrics

```promql
up{job="payment-service"}
```

Expected:

```text
1
```

Meaning:

```text
Target Reachable
```

---

## Check Metrics Endpoint

Port-forward:

```bash
kubectl port-forward svc/payment-service 8080:8080
```

Test:

```bash
curl localhost:8080/metrics
```

Expected:

```text
http_requests_total 1204
process_cpu_seconds_total 18.2
```

Metrics available.

---

## Grafana Verification

Open dashboard.

Expected:

```text
Request Rate
CPU Usage
Memory Usage
Latency
```

Graphs return.

No more:

```text
No Data
```

---

# Production Recovery Workflow

```text
Grafana No Data
      │
      ▼
Check Prometheus Targets
      │
      ▼
Target DOWN
      │
      ▼
Inspect ServiceMonitor
      │
      ▼
Inspect Service
      │
      ▼
Compare Port Names
      │
      ▼
Mismatch Found
      │
      ▼
Update Configuration
      │
      ▼
Target UP
      │
      ▼
Metrics Restored
```

---

# Other Common ServiceMonitor Failures

## Wrong Namespace Selector

```yaml
namespaceSelector:
  matchNames:
    - monitoring
```

Service exists in:

```text
default
```

No targets discovered.

---

## Wrong Label Selector

```yaml
selector:
  matchLabels:
    app: payment
```

Service:

```yaml
labels:
  app: payment-v2
```

No Service found.

---

## Wrong Metrics Path

ServiceMonitor:

```yaml
path: /metrics
```

Application:

```text
/prometheus
```

Scrape fails.

---

## Wrong Target Port

```yaml
targetPort: 9090
```

Application listens:

```text
8080
```

Connection fails.

---

# Summary

## What Happened?

```text
ServiceMonitor
port=metrics
      │
      ▼
Service
port=prometheus
      │
      ▼
No Match
      │
      ▼
Prometheus Cannot Scrape
      │
      ▼
Target DOWN
      │
      ▼
Grafana No Data
```

---

## Root Cause

The ServiceMonitor referenced:

```yaml
port: metrics
```

but the Service exposed:

```yaml
name: prometheus
```

Prometheus Operator matches Service ports by NAME.

Because the names differed, the target could not be scraped.

---

## Immediate Fix

Update either:

```yaml
ServiceMonitor.port
```

or

```yaml
Service.ports[].name
```

so both use the same value.

Example:

```yaml
port: prometheus
```

---

## Long-Term Prevention

* Standardize metrics port naming
* Use Helm values for port names
* Validate ServiceMonitor during CI/CD
* Add Prometheus target alerts
* Monitor scrape failures

---

# How Prometheus Service Discovery Works

```text
ServiceMonitor
      │
      ▼
Find Service
      │
      ▼
Match Port Name
      │
      ▼
Discover Endpoint
      │
      ▼
Scrape /metrics
      │
      ▼
Store Metrics
      │
      ▼
Grafana Queries Metrics
```

If the port name does not match:

```text
Service Discovery Fails
```

---

# Interview Answer

> "The monitoring outage was caused by a ServiceMonitor port mismatch. The ServiceMonitor was configured to scrape a port named `metrics`, while the Kubernetes Service exposed a port named `prometheus`. Prometheus Operator resolves targets using the Service port name, not the port number, so it could not discover a valid scrape endpoint. This caused the target to go DOWN, resulting in Grafana showing No Data. I would verify the ServiceMonitor, Service, Endpoints, and Prometheus targets, then update the port names so they match. After applying the fix, I would confirm the target status becomes UP and metrics are visible again in Grafana."

---

# Commands Cheat Sheet

```bash
# Check ServiceMonitor
kubectl get servicemonitor payment-service -o yaml

# Check Service
kubectl get svc payment-service -o yaml

# Describe Service
kubectl describe svc payment-service

# Check Endpoints
kubectl get endpoints payment-service

# Check Prometheus Targets
kubectl port-forward svc/prometheus 9090:9090

# Test metrics endpoint
kubectl port-forward svc/payment-service 8080:8080
curl localhost:8080/metrics

# Verify Prometheus query
up{job="payment-service"}

# Apply fix
kubectl apply -f servicemonitor.yaml

# Watch targets
kubectl get servicemonitor -A
```
