# Exercise 19 — Helm Chart Engineering

## Objective

Build a production-grade reusable Helm chart that supports replicas, resources, ConfigMaps, Secrets, Ingress, and HPA across dev, qa, and prod environments.

---

## Final directory structure

```
payment-service/
├── Chart.yaml
├── values.yaml
├── values-dev.yaml
├── values-qa.yaml
├── values-prod.yaml
├── templates/
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── ingress.yaml
│   ├── hpa.yaml
│   ├── configmap.yaml
│   └── secret.yaml
└── README.md
```

---

## Prerequisites

```bash
brew install helm
helm version
```

Expected:

```
version.BuildInfo{Version:"v3.x.x"}
```

---

## Step 1 — Create chart scaffold

```bash
helm create payment-service
cd payment-service
```

Remove unused files:

```bash
rm -rf templates/tests
rm -f templates/NOTES.txt
```

---

## Step 2 — Chart.yaml

```yaml
apiVersion: v2
name: payment-service
description: Production Ready Payment Service
type: application
version: 1.0.0
appVersion: "1.0.0"
```

---

## Step 3 — values.yaml (base defaults)

```yaml
replicaCount: 2

image:
  repository: nginx
  tag: "latest"
  pullPolicy: IfNotPresent

service:
  type: ClusterIP
  port: 80

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi

config:
  APP_ENV: dev
  LOG_LEVEL: info

secret:
  dbPassword: ""

ingress:
  enabled: false
  className: nginx
  host: app.local

autoscaling:
  enabled: false
  minReplicas: 2
  maxReplicas: 5
  targetCPUUtilizationPercentage: 70
```

---

## Step 4 — templates/configmap.yaml

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .Release.Name }}-config
data:
  APP_ENV: {{ .Values.config.APP_ENV | quote }}
  LOG_LEVEL: {{ .Values.config.LOG_LEVEL | quote }}
```

---

## Step 5 — templates/secret.yaml

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: {{ .Release.Name }}-secret
type: Opaque
stringData:
  DB_PASSWORD: {{ required "DB_PASSWORD is required" .Values.secret.dbPassword | quote }}
```

> `required` makes Helm fail loudly if no password is passed — no hardcoded values ever.

---

## Step 6 — templates/deployment.yaml

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}
  labels:
    helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
    app.kubernetes.io/name: {{ .Chart.Name }}
    app.kubernetes.io/instance: {{ .Release.Name }}
    app.kubernetes.io/managed-by: {{ .Release.Service }}
spec:
  {{- if not .Values.autoscaling.enabled }}
  replicas: {{ .Values.replicaCount }}
  {{- end }}
  selector:
    matchLabels:
      app.kubernetes.io/name: {{ .Chart.Name }}
      app.kubernetes.io/instance: {{ .Release.Name }}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: {{ .Chart.Name }}
        app.kubernetes.io/instance: {{ .Release.Name }}
    spec:
      containers:
        - name: {{ .Chart.Name }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - name: http
              containerPort: 80
              protocol: TCP
          envFrom:
            - configMapRef:
                name: {{ .Release.Name }}-config
            - secretRef:
                name: {{ .Release.Name }}-secret
          livenessProbe:
            httpGet:
              path: /
              port: http
          readinessProbe:
            httpGet:
              path: /
              port: http
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
```

> `{{- if not .Values.autoscaling.enabled }}` — replicas line is skipped in prod so HPA has full control. Dev and QA render it normally.

---

## Step 7 — templates/service.yaml

```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}
  labels:
    app.kubernetes.io/name: {{ .Chart.Name }}
    app.kubernetes.io/instance: {{ .Release.Name }}
spec:
  type: {{ .Values.service.type }}
  selector:
    app.kubernetes.io/name: {{ .Chart.Name }}
    app.kubernetes.io/instance: {{ .Release.Name }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: http
      protocol: TCP
      name: http
```

---

## Step 8 — templates/ingress.yaml

```yaml
{{- if .Values.ingress.enabled }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ .Release.Name }}
  labels:
    app.kubernetes.io/name: {{ .Chart.Name }}
    app.kubernetes.io/instance: {{ .Release.Name }}
spec:
  ingressClassName: {{ .Values.ingress.className }}
  rules:
    - host: {{ .Values.ingress.host }}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: {{ .Release.Name }}
                port:
                  number: {{ .Values.service.port }}
{{- end }}
```

> Ingress only renders when `ingress.enabled: true` — disabled in dev, enabled in qa and prod.

---

## Step 9 — templates/hpa.yaml

```yaml
{{- if .Values.autoscaling.enabled }}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ .Release.Name }}
  labels:
    app.kubernetes.io/name: {{ .Chart.Name }}
    app.kubernetes.io/instance: {{ .Release.Name }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {{ .Release.Name }}
  minReplicas: {{ .Values.autoscaling.minReplicas }}
  maxReplicas: {{ .Values.autoscaling.maxReplicas }}
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: {{ .Values.autoscaling.targetCPUUtilizationPercentage }}
{{- end }}
```

> HPA only renders in prod. When enabled, the `replicas:` field is omitted from Deployment so they don't conflict.

---

## Step 10 — Environment values files

### values-dev.yaml

```yaml
replicaCount: 1

secret:
  dbPassword: "dev-password-123"

config:
  APP_ENV: dev
  LOG_LEVEL: info

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi

ingress:
  enabled: false

autoscaling:
  enabled: false
```

### values-qa.yaml

```yaml
replicaCount: 2

secret:
  dbPassword: "qa-password-456"

config:
  APP_ENV: qa
  LOG_LEVEL: info

resources:
  requests:
    cpu: 200m
    memory: 256Mi
  limits:
    cpu: 500m
    memory: 512Mi

ingress:
  enabled: true
  host: qa.example.com

autoscaling:
  enabled: false
```

### values-prod.yaml

```yaml
replicaCount: 5

secret:
  dbPassword: ""    # injected via --set in CI/CD, never committed to Git

config:
  APP_ENV: prod
  LOG_LEVEL: info

resources:
  requests:
    cpu: 500m
    memory: 512Mi
  limits:
    cpu: "2"
    memory: 2Gi

ingress:
  enabled: true
  host: prod.example.com

autoscaling:
  enabled: true
  minReplicas: 5
  maxReplicas: 20
  targetCPUUtilizationPercentage: 70
```

---

## Step 11 — Render and verify each environment

### Dev

```bash
helm template payment-service . -f values-dev.yaml
```

Check:
- `replicas: 1` present in Deployment
- No Ingress rendered
- No HPA rendered
- `APP_ENV: dev` in ConfigMap

### QA

```bash
helm template payment-service . -f values-qa.yaml
```

Check:
- `replicas: 2` present in Deployment
- Ingress rendered with `qa.example.com`
- No HPA rendered
- `APP_ENV: qa` in ConfigMap

### Prod

```bash
helm template payment-service . -f values-prod.yaml \
  --set secret.dbPassword="prod-secret-xyz"
```

Check:
- No `replicas:` line in Deployment (HPA controls it)
- Ingress rendered with `prod.example.com`
- HPA rendered with `minReplicas: 5`, `maxReplicas: 20`
- `APP_ENV: prod` in ConfigMap
- Bigger resources: `cpu: "2"`, `memory: 2Gi`

### Verify replicas behaviour

```bash
# Dev — should show replicas: 1
helm template payment-service . -f values-dev.yaml | grep -A2 "replicas"

# QA — should show replicas: 2
helm template payment-service . -f values-qa.yaml | grep -A2 "replicas"

# Prod — should show only minReplicas/maxReplicas from HPA, no replicas in Deployment
helm template payment-service . -f values-prod.yaml \
  --set secret.dbPassword="prod-secret-xyz" | grep -A2 "replicas"
```

Expected prod output:

```
minReplicas: 5
maxReplicas: 20
```

No `replicas:` in the Deployment section.

---

## Step 12 — Lint

```bash
helm lint .
```

Expected:

```
==> Linting .
1 chart(s) linted, 0 chart(s) failed
```

---

## Step 13 — Package

```bash
helm package .
```

Expected:

```
Successfully packaged chart and saved it to: payment-service-1.0.0.tgz
```

---

## Step 14 — Create namespaces and install each environment

### Create namespaces first

```bash
kubectl create namespace dev
kubectl create namespace qa
kubectl create namespace prod
```

Expected:

```
namespace/dev created
namespace/qa created
namespace/prod created
```

Verify:

```bash
kubectl get ns | grep -E "dev|qa|prod"
```

Expected:

```
dev     Active   5s
qa      Active   5s
prod    Active   5s
```

---

### Install Dev

```bash
helm install payment-service . \
  -f values-dev.yaml \
  --namespace dev
```

Expected:

```
NAME: payment-service
STATUS: deployed
REVISION: 1
```

Verify:

```bash
kubectl get all -n dev
```

Expected:

```
NAME                                    READY   STATUS    RESTARTS
pod/payment-service-xxxxxxx-xxxxx       1/1     Running   0

NAME                      TYPE        CLUSTER-IP    PORT(S)
service/payment-service   ClusterIP   10.96.x.x     80/TCP

NAME                              READY   UP-TO-DATE   AVAILABLE
deployment.apps/payment-service   1/1     1            1
```

---

### Install QA

```bash
helm install payment-service . \
  -f values-qa.yaml \
  --namespace qa
```

Expected:

```
NAME: payment-service
STATUS: deployed
REVISION: 1
```

Verify:

```bash
kubectl get all -n qa
```

Expected:

```
NAME                                    READY   STATUS    RESTARTS
pod/payment-service-xxxxxxx-xxxxx       1/1     Running   0
pod/payment-service-xxxxxxx-yyyyy       1/1     Running   0

NAME                      TYPE        CLUSTER-IP    PORT(S)
service/payment-service   ClusterIP   10.96.x.x     80/TCP

NAME                              READY   UP-TO-DATE   AVAILABLE
deployment.apps/payment-service   2/2     2            2
```

---

### Install Prod

```bash
helm install payment-service . \
  -f values-prod.yaml \
  --set secret.dbPassword="prod-secret-xyz" \
  --namespace prod
```

Expected:

```
NAME: payment-service
STATUS: deployed
REVISION: 1
```

Verify:

```bash
kubectl get all -n prod
```

Expected:

```
NAME                                    READY   STATUS    RESTARTS
pod/payment-service-xxxxxxx-xxxxx       1/1     Running   0
... (5 pods — minReplicas)

NAME                      TYPE        CLUSTER-IP    PORT(S)
service/payment-service   ClusterIP   10.96.x.x     80/TCP

NAME                              READY   UP-TO-DATE   AVAILABLE
deployment.apps/payment-service   5/5     5            5

NAME                                              REFERENCE                    TARGETS   MINPODS   MAXPODS
horizontalpodautoscaler.autoscaling/payment-service   Deployment/payment-service   0%/70%    5         20
```

---

## Step 15 — Test each environment

### Dev — port 8080

```bash
kubectl port-forward svc/payment-service 8080:80 -n dev
```

Open new terminal:

```bash
curl http://localhost:8080
```

Expected:

```html
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
```

Verify env vars injected inside pod:

```bash
kubectl exec -it \
  $(kubectl get pod -n dev -o jsonpath='{.items[0].metadata.name}') \
  -n dev -- env | grep -E "APP_ENV|LOG_LEVEL|DB_PASSWORD"
```

Expected:

```
APP_ENV=dev
LOG_LEVEL=info
DB_PASSWORD=dev-password-123
```

Verify liveness and readiness probes:

```bash
kubectl describe pod -n dev | grep -A5 "Liveness\|Readiness"
```

Expected:

```
Liveness:   http-get http://:http/ delay=0s timeout=1s period=10s
Readiness:  http-get http://:http/ delay=0s timeout=1s period=10s
```

---

### QA — port 7070

```bash
kubectl port-forward svc/payment-service 7070:80 -n qa
```

Open new terminal:

```bash
curl http://localhost:7070
```

Expected:

```html
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
```

Verify env vars:

```bash
kubectl exec -it \
  $(kubectl get pod -n qa -o jsonpath='{.items[0].metadata.name}') \
  -n qa -- env | grep -E "APP_ENV|LOG_LEVEL|DB_PASSWORD"
```

Expected:

```
APP_ENV=qa
LOG_LEVEL=info
DB_PASSWORD=qa-password-456
```

Verify probes:

```bash
kubectl describe pod -n qa | grep -A5 "Liveness\|Readiness"
```

Expected:

```
Liveness:   http-get http://:http/ delay=0s timeout=1s period=10s
Readiness:  http-get http://:http/ delay=0s timeout=1s period=10s
```

---

### Prod — port 6060

```bash
kubectl port-forward svc/payment-service 6060:80 -n prod
```

Open new terminal:

```bash
curl http://localhost:6060
```

Expected:

```html
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
```

Verify env vars:

```bash
kubectl exec -it \
  $(kubectl get pod -n prod -o jsonpath='{.items[0].metadata.name}') \
  -n prod -- env | grep -E "APP_ENV|LOG_LEVEL|DB_PASSWORD"
```

Expected:

```
APP_ENV=prod
LOG_LEVEL=info
DB_PASSWORD=prod-secret-xyz
```

Verify probes:

```bash
kubectl describe pod -n prod | grep -A5 "Liveness\|Readiness"
```

Expected:

```
Liveness:   http-get http://:http/ delay=0s timeout=1s period=10s
Readiness:  http-get http://:http/ delay=0s timeout=1s period=10s
```

Verify HPA is active:

```bash
kubectl get hpa -n prod
```

Expected:

```
NAME              REFERENCE                    TARGETS   MINPODS   MAXPODS   REPLICAS
payment-service   Deployment/payment-service   0%/70%    5         20        5
```

---

## Step 16 — Upgrade test

Change replica count on dev and upgrade:

```bash
helm upgrade payment-service . \
  -f values-dev.yaml \
  --set replicaCount=3 \
  --namespace dev
```

Verify:

```bash
kubectl get deploy -n dev
```

Expected:

```
NAME              READY   UP-TO-DATE   AVAILABLE
payment-service   3/3     3            3
```

---

## Step 17 — Uninstall all environments

```bash
helm uninstall payment-service -n dev
helm uninstall payment-service -n qa
helm uninstall payment-service -n prod
```

Expected:

```
release "payment-service" uninstalled
release "payment-service" uninstalled
release "payment-service" uninstalled
```

Verify everything removed:

```bash
kubectl get all -n dev
kubectl get all -n qa
kubectl get all -n prod
```

Expected:

```
No resources found in dev namespace.
No resources found in qa namespace.
No resources found in prod namespace.
```

---

## What each environment renders

| Feature | dev | qa | prod |
|---|---|---|---|
| namespace | dev | qa | prod |
| replicas | 1 (fixed) | 2 (fixed) | controlled by HPA |
| port-forward | 8080 | 7070 | 6060 |
| ingress | disabled | qa.example.com | prod.example.com |
| HPA | disabled | disabled | min 5, max 20 |
| resources | small | medium | large |
| secret | values file | values file | injected via --set |

---

## Key decisions to explain in interview

### Why replicas is omitted in prod deployment

When HPA is enabled, having a fixed `replicas:` in the Deployment causes conflicts — every Helm sync resets the replica count back, overriding what HPA decided. The `{{- if not .Values.autoscaling.enabled }}` block skips the replicas field entirely in prod so HPA has full control.

### Why secrets use required and not hardcoded values

`required` makes Helm fail at template time if no value is provided. In prod, `dbPassword` is empty in the values file — the real password is injected by CI/CD via `--set secret.dbPassword=$SECRET` so it never touches Git.

### Why separate namespaces per environment

Each environment is completely isolated — different namespace, different configs, different secrets. One cluster can host all three environments safely without them interfering with each other.

### Why one chart for all environments

Same chart, different values files. This means one place to fix bugs, one place to add features, consistent resource definitions across all envs. GitOps-friendly — values files are committed, secrets are not.

---

## Interview answer (say this)

> "I built a reusable Helm chart by parameterizing replicas, resources, ConfigMaps, Secrets, Ingress, and HPA through values files. Each environment gets its own namespace — dev, qa, prod — for full isolation. Dev has 1 replica, no ingress, no autoscaling. QA has 2 replicas with ingress. Prod has HPA with min 5 and max 20 replicas — and when HPA is enabled, the replicas field is conditionally omitted from the Deployment using an if block so they don't conflict. Secrets use the required function so Helm fails loudly if no password is passed — the prod password is never in Git, it's injected at deploy time via --set from the CI/CD pipeline. I validate with helm lint and helm template before every deploy, test with port-forward to verify env vars and probes, and package with helm package for distribution."