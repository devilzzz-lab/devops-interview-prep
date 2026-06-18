# Exercise 21 — Production ALB Ingress Setup

## Objective

Expose three applications using a single ALB Ingress with SSL, HTTP → HTTPS redirect, and health checks per service.

## Routes

```
/api/*         → api-service:8080
/admin/*       → admin-service:9090
/dashboard/*   → dashboard-service:3000
```

## Architecture

```
Internet / User
 ↓
Application Load Balancer (HTTPS :443 + HTTP :80 redirect)
 ↓  ACM Certificate (SSL termination)
Kubernetes Ingress (aws-load-balancer-controller)
 ↓              ↓                ↓
/api/*       /admin/*       /dashboard/*
api-service  admin-service  dashboard-service
port 8080    port 9090      port 3000
```

---

## Prerequisites

```bash
# Install kubectl
brew install kubectl

# Install kubeconform (schema validation without cluster)
brew install kubeconform
```

---

## Step 1 — Write the Ingress manifest

Save as `ingress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: payment-platform-ingress
  namespace: production
  annotations:
    # Tell Kubernetes to use AWS ALB controller
    kubernetes.io/ingress.class: alb

    # ALB listens on both 80 and 443
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'

    # Redirect all HTTP traffic to HTTPS
    alb.ingress.kubernetes.io/ssl-redirect: "443"

    # Use ip mode — traffic goes directly to pod IPs
    alb.ingress.kubernetes.io/target-type: ip

    # Your ACM certificate ARN for SSL
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:ap-south-1:123456789012:certificate/abc-123

    # ALB scheme — internet-facing for public traffic
    alb.ingress.kubernetes.io/scheme: internet-facing

    # Health check settings per target group
    alb.ingress.kubernetes.io/healthcheck-protocol: HTTP
    alb.ingress.kubernetes.io/healthcheck-interval-seconds: "30"
    alb.ingress.kubernetes.io/healthcheck-timeout-seconds: "5"
    alb.ingress.kubernetes.io/healthy-threshold-count: "2"
    alb.ingress.kubernetes.io/unhealthy-threshold-count: "3"

spec:
  rules:
    - http:
        paths:
          # Route 1 — API service
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: api-service
                port:
                  number: 8080

          # Route 2 — Admin service
          - path: /admin
            pathType: Prefix
            backend:
              service:
                name: admin-service
                port:
                  number: 9090

          # Route 3 — Dashboard service
          - path: /dashboard
            pathType: Prefix
            backend:
              service:
                name: dashboard-service
                port:
                  number: 3000
```

---

## Step 2 — Write the Services (one per app)

Save as `services.yaml`:

```yaml
# API Service
apiVersion: v1
kind: Service
metadata:
  name: api-service
  namespace: production
  annotations:
    alb.ingress.kubernetes.io/healthcheck-path: /api/health
spec:
  type: ClusterIP
  selector:
    app: api-service
  ports:
    - port: 8080
      targetPort: 8080
      protocol: TCP
---
# Admin Service
apiVersion: v1
kind: Service
metadata:
  name: admin-service
  namespace: production
  annotations:
    alb.ingress.kubernetes.io/healthcheck-path: /admin/health
spec:
  type: ClusterIP
  selector:
    app: admin-service
  ports:
    - port: 9090
      targetPort: 9090
      protocol: TCP
---
# Dashboard Service
apiVersion: v1
kind: Service
metadata:
  name: dashboard-service
  namespace: production
  annotations:
    alb.ingress.kubernetes.io/healthcheck-path: /dashboard/health
spec:
  type: ClusterIP
  selector:
    app: dashboard-service
  ports:
    - port: 3000
      targetPort: 3000
      protocol: TCP
```

---

## Step 3 — Validate YAML without a cluster

### Method 1 — kubectl dry-run (client side, no cluster needed)

```bash
kubectl apply -f ingress.yaml --dry-run=client
```

Expected:
```
ingress.networking.k8s.io/payment-platform-ingress created (dry run)
```

```bash
kubectl apply -f services.yaml --dry-run=client
```

Expected:
```
service/api-service created (dry run)
service/admin-service created (dry run)
service/dashboard-service created (dry run)
```

### Method 2 — kubeconform (validates against K8s schema)

```bash
kubeconform ingress.yaml
kubeconform services.yaml
```

Expected (silence = success):
```
# no output = valid
```

If there's an error:
```
ingress.yaml - Ingress payment-platform-ingress is invalid: ...
```

### Method 3 — kubectl explain (understand any field)

```bash
# Understand ingress spec
kubectl explain ingress.spec.rules

# Understand pathType options
kubectl explain ingress.spec.rules.http.paths.pathType
```

---

## Step 4 — Verify structure is correct

```bash
kubectl apply -f ingress.yaml --dry-run=client -o yaml
```

Check these fields in the output:

```yaml
# ✅ annotations present
annotations:
  alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
  alb.ingress.kubernetes.io/ssl-redirect: "443"
  alb.ingress.kubernetes.io/target-type: ip
  alb.ingress.kubernetes.io/scheme: internet-facing

# ✅ three paths present
spec:
  rules:
    - http:
        paths:
          - path: /api        ← route 1
          - path: /admin      ← route 2
          - path: /dashboard  ← route 3
```

---

## Step 5 — Apply on kind cluster (optional)

```bash
# Switch to kind cluster
kubectl config use-context kind-debug-cluster

# Create namespace
kubectl create namespace production

# Apply services first
kubectl apply -f services.yaml -n production

# Apply ingress
kubectl apply -f ingress.yaml -n production
```

Expected:
```
service/api-service created
service/admin-service created
service/dashboard-service created
ingress.networking.k8s.io/payment-platform-ingress created
```

Check ingress was created:

```bash
kubectl get ingress -n production
```

Expected:
```
NAME                        CLASS   HOSTS   ADDRESS   PORTS   AGE
payment-platform-ingress    alb     *                 80      5s
```

> ADDRESS will be empty in kind — ALB controller is not running locally.
> That is expected — the manifest is valid, you are just practicing writing it.

Check services:

```bash
kubectl get svc -n production
```

Expected:
```
NAME                 TYPE        CLUSTER-IP      PORT(S)
api-service          ClusterIP   10.96.x.x       8080/TCP
admin-service        ClusterIP   10.96.x.x       9090/TCP
dashboard-service    ClusterIP   10.96.x.x       3000/TCP
```

Describe ingress to see rules:

```bash
kubectl describe ingress payment-platform-ingress -n production
```

Expected:
```
Name:             payment-platform-ingress
Namespace:        production
Rules:
  Host        Path         Backends
  ----        ----         --------
  *           /api         api-service:8080
              /admin       admin-service:9090
              /dashboard   dashboard-service:3000
Annotations:
  alb.ingress.kubernetes.io/listen-ports:   [{"HTTP":80},{"HTTPS":443}]
  alb.ingress.kubernetes.io/ssl-redirect:   443
  alb.ingress.kubernetes.io/target-type:    ip
  alb.ingress.kubernetes.io/scheme:         internet-facing
```

---

## Step 6 — Cleanup

```bash
kubectl delete -f ingress.yaml -n production
kubectl delete -f services.yaml -n production
kubectl delete namespace production
```

Expected:
```
ingress.networking.k8s.io "payment-platform-ingress" deleted
service "api-service" deleted
service "admin-service" deleted
service "dashboard-service" deleted
namespace "production" deleted
```

---

## Key annotations explained

| Annotation | What it does |
|---|---|
| `listen-ports: HTTP:80, HTTPS:443` | ALB accepts both ports |
| `ssl-redirect: 443` | HTTP requests auto-redirected to HTTPS |
| `target-type: ip` | Traffic goes directly to pod IP, not node |
| `scheme: internet-facing` | ALB is public, not internal |
| `certificate-arn` | ACM cert ARN for SSL termination |
| `healthcheck-path` | ALB pings this path per target group |
| `healthcheck-interval-seconds` | How often ALB checks health |
| `healthy-threshold-count` | Checks needed to mark healthy |
| `unhealthy-threshold-count` | Failures needed to mark unhealthy |

---

## pathType options

| pathType | Behaviour |
|---|---|
| `Prefix` | Matches `/api` and `/api/anything` |
| `Exact` | Matches only `/api` exactly |
| `ImplementationSpecific` | Controller decides |

Use `Prefix` for all routes in this exercise.

---

## target-type: ip vs instance

| target-type | Traffic flow |
|---|---|
| `ip` | ALB → Pod IP directly (recommended) |
| `instance` | ALB → Node → Pod (extra hop) |

Always use `ip` with EKS — it's more efficient and avoids NodePort.

---

## HTTP → HTTPS redirect flow

```
User hits http://example.com/api/orders
 ↓
ALB listener on port 80
 ↓
ssl-redirect: 443 annotation triggers
 ↓
ALB returns 301 → https://example.com/api/orders
 ↓
User follows redirect to HTTPS
 ↓
ALB listener on port 443 (ACM cert terminates SSL)
 ↓
Routes to api-service:8080
```

The redirect happens at the ALB level — your application never sees HTTP traffic.

---

## Interview answer (say this)

> "For ALB Ingress I set listen-ports to accept both HTTP 80 and HTTPS 443, then use ssl-redirect to automatically redirect all HTTP traffic to HTTPS — this is handled at the ALB listener level, not the application. I set target-type to ip so traffic goes directly to pod IPs instead of going through node ports, which is more efficient and avoids an extra hop. The certificate-arn annotation points to the ACM certificate for SSL termination. Each path rule routes to a separate ClusterIP service — /api to api-service on 8080, /admin to admin-service on 9090, /dashboard to dashboard-service on 3000. Health checks are configured per service via annotations so ALB knows which endpoint to ping before sending live traffic to a pod."