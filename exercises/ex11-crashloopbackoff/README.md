# Exercise 11 — CrashLoopBackOff Investigation

## Incident

A production application is continuously restarting.

### Pod Status

```bash
kubectl get pods
```

Output:

```text
NAME                READY   STATUS             RESTARTS
payment-service     0/1     CrashLoopBackOff   15
```

---

## Application Logs

```text
panic:
dial tcp 10.20.0.15:5432
connection refused
```

---

## Events

```text
Back-off restarting failed container
```

---

# Architecture (Expected)

```text
Payment Service
      │
      ▼
Database Secret
      │
      ▼
PostgreSQL Service
      │
      ▼
PostgreSQL Pod
      │
      ▼
Database Connection Successful
      │
      ▼
Application Starts
```

---

# Architecture (Broken)

```text
Payment Service
      │
      ▼
Attempts Connection
10.20.0.15:5432
      │
      ▼
Connection Refused
      │
      ▼
Application Panic
      │
      ▼
Container Exits
      │
      ▼
Kubelet Restarts Container
      │
      ▼
CrashLoopBackOff
```

---

# Root Cause Analysis

## What does "connection refused" mean?

The application successfully reached:

```text
10.20.0.15
```

and attempted:

```text
TCP Port 5432
```

but the destination rejected the connection.

This is a critical clue.

---

## Understanding Possible Failure Types

### DNS Failure

Typical error:

```text
lookup postgres.default.svc.cluster.local:
no such host
```

or

```text
temporary failure in name resolution
```

Architecture:

```text
Application
      │
      ▼
DNS Query
      │
      ▼
Fails
      │
      ▼
Cannot Resolve Hostname
```

---

### Database Not Reachable

Typical error:

```text
dial tcp 10.20.0.15:5432:
connection refused
```

Architecture:

```text
Application
      │
      ▼
Database IP Resolved
      │
      ▼
Port Closed
      │
      ▼
Connection Refused
```

---

### Secret Failure

Typical errors:

```text
authentication failed
```

or

```text
password authentication failed
```

or

```text
missing environment variable
```

Architecture:

```text
Application
      │
      ▼
Connects To Database
      │
      ▼
Authentication Fails
```

---

# Task 1 — Is This a DNS Issue?

## Answer

No.

Why?

The application already resolved an IP:

```text
10.20.0.15
```

If DNS were broken, the error would contain:

```text
no such host
```

or

```text
could not resolve hostname
```

Instead:

```text
dial tcp 10.20.0.15:5432
```

shows DNS resolution already succeeded.

---

## Verification

Check environment variables:

```bash
kubectl describe pod payment-service
```

Look for:

```text
DB_HOST=postgres
```

Then test DNS:

```bash
kubectl run dns-test \
  --rm -it \
  --image=busybox
```

Inside pod:

```bash
nslookup postgres
```

Expected:

```text
Name: postgres
Address: 10.20.0.15
```

DNS works.

---

# Conclusion

```text
DNS Issue = NO
```

---

# Task 2 — Is This a Database Issue?

## Answer

Most likely YES.

The error:

```text
connection refused
```

means:

```text
Target Host Reachable
Port Not Accepting Connections
```

This usually indicates:

* Database Pod not running
* Database container crashed
* Database process not started
* Wrong Service targetPort
* Database listening on another port

---

## Step 1 — Check Database Pods

```bash
kubectl get pods
```

Example:

```text
NAME           READY   STATUS
postgres       0/1     CrashLoopBackOff
```

or

```text
postgres       0/1     Error
```

Problem found.

---

## Step 2 — Check Database Logs

```bash
kubectl logs postgres
```

Example:

```text
FATAL:
database files missing
```

or

```text
password authentication failed
```

or

```text
permission denied
```

---

## Step 3 — Verify Service

```bash
kubectl get svc postgres
```

Expected:

```text
NAME       TYPE        CLUSTER-IP
postgres   ClusterIP   10.20.0.15
```

Verify:

```bash
kubectl describe svc postgres
```

Example:

```yaml
Port: 5432/TCP
TargetPort: 5432
```

---

## Step 4 — Check Endpoints

```bash
kubectl get endpoints postgres
```

Healthy:

```text
NAME       ENDPOINTS
postgres   10.1.2.15:5432
```

Broken:

```text
NAME       ENDPOINTS
postgres   <none>
```

This means no database pod is backing the Service.

---

## Step 5 — Test Connectivity

Launch debug pod:

```bash
kubectl run debug \
  --rm -it \
  --image=nicolaka/netshoot
```

Test:

```bash
nc -vz 10.20.0.15 5432
```

Expected:

```text
Connection refused
```

Confirms database side issue.

---

# Conclusion

```text
Database Issue = YES
```

---

# Task 3 — Is This a Secret Issue?

## Answer

Possibly, but not the primary symptom.

Why?

A secret issue normally causes:

```text
authentication failed
```

Example:

```text
FATAL:
password authentication failed for user payment
```

or

```text
missing environment variable DB_PASSWORD
```

The current error:

```text
connection refused
```

occurs before authentication even begins.

The application cannot establish a TCP session.

Therefore:

```text
Network Connection Fails First
Authentication Never Starts
```

---

## Verify Secret

Check secret exists:

```bash
kubectl get secret payment-db-secret
```

Inspect:

```bash
kubectl describe secret payment-db-secret
```

Verify deployment:

```bash
kubectl describe deploy payment-service
```

Look for:

```yaml
env:
  - name: DB_USER
  - name: DB_PASSWORD
```

---

## Decode Secret

```bash
kubectl get secret payment-db-secret \
-o jsonpath='{.data.password}' \
| base64 -d
```

Verify value.

---

# Conclusion

```text
Secret Issue = Unlikely
```

Current evidence points to database availability.

---

# Investigation Flow

```text
CrashLoopBackOff
       │
       ▼
Check Logs
       │
       ▼
connection refused
       │
       ▼
DNS Resolved?
       │
       ▼
YES
       │
       ▼
Check Database
       │
       ▼
Pod Running?
       │
       ▼
Endpoints Exist?
       │
       ▼
Port Listening?
       │
       ▼
Root Cause Found
```

---

# Most Likely Root Causes

## Scenario 1 — Database Pod Down

```text
postgres
CrashLoopBackOff
```

Most common.

---

## Scenario 2 — Empty Endpoints

```text
kubectl get endpoints postgres

<none>
```

Service has no backend pods.

---

## Scenario 3 — Wrong Target Port

Service:

```yaml
targetPort: 5432
```

Container:

```yaml
containerPort: 5433
```

Port mismatch.

---

## Scenario 4 — PostgreSQL Not Started

```text
PostgreSQL process crashed
```

Container running but port closed.

---

# Recovery Steps

## Step 1

Check database health.

```bash
kubectl get pods
```

---

## Step 2

Inspect logs.

```bash
kubectl logs postgres
```

---

## Step 3

Verify Service.

```bash
kubectl describe svc postgres
```

---

## Step 4

Verify Endpoints.

```bash
kubectl get endpoints postgres
```

---

## Step 5

Restart database if fixed.

```bash
kubectl rollout restart deployment postgres
```

---

## Step 6

Watch payment-service recover.

```bash
kubectl get pods -w
```

Expected:

```text
payment-service

Running
```

---

# Summary

## What Happened?

```text
Payment Service
      │
      ▼
Connect To Database
10.20.0.15:5432
      │
      ▼
Connection Refused
      │
      ▼
Application Panic
      │
      ▼
Container Exit
      │
      ▼
CrashLoopBackOff
```

---

## DNS Issue?

```text
NO
```

Reason:

```text
IP Address Already Resolved
```

---

## Database Issue?

```text
YES
```

Reason:

```text
Connection Refused
```

Database service or database pod is not accepting connections.

---

## Secret Issue?

```text
UNLIKELY
```

Reason:

```text
Authentication Never Started
```

Connection failed before credentials were used.

---

# Final Diagnosis

```text
DNS          = Healthy
Secret       = Likely Healthy
Database     = Failed
```

Most probable root cause:

```text
PostgreSQL Pod Down
OR
Service Has No Endpoints
OR
Port 5432 Not Listening
```

---

# Interview Answer

> "The CrashLoopBackOff was caused by the application failing to connect to its PostgreSQL database. The key clue is the error `dial tcp 10.20.0.15:5432: connection refused`. Since an IP address is already resolved, this is not a DNS issue. A secret problem would typically produce authentication errors such as 'password authentication failed', but here the TCP connection itself is being rejected before authentication begins. I would investigate the PostgreSQL pod status, logs, Service configuration, and Endpoints. The most likely root cause is that the database pod is down, the Service has no endpoints, or PostgreSQL is not listening on port 5432."

---

# Commands Cheat Sheet

```bash
# Check application pod
kubectl get pods

# View application logs
kubectl logs payment-service

# Describe pod
kubectl describe pod payment-service

# Check database pods
kubectl get pods

# Check database logs
kubectl logs postgres

# Verify service
kubectl get svc postgres
kubectl describe svc postgres

# Verify endpoints
kubectl get endpoints postgres

# DNS test
kubectl run dns-test --rm -it --image=busybox

# Connectivity test
kubectl run debug --rm -it --image=nicolaka/netshoot
nc -vz 10.20.0.15 5432

# Inspect secrets
kubectl get secret
kubectl describe secret payment-db-secret

# Watch recovery
kubectl get pods -w
```
