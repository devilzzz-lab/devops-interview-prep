# Exercise 19 — Helm Chart Engineering (Local Practice Guide)

## Objective

Build a production-grade reusable Helm chart that supports:

* Replicas
* Resources
* ConfigMaps
* Secrets
* Ingress
* HPA (Autoscaling)

Environment-specific deployments:

* dev
* qa
* prod

Expected deliverables:

```text
helm-chart/
├── Chart.yaml
├── values.yaml
├── values-dev.yaml
├── values-qa.yaml
├── values-prod.yaml
├── templates/
├── README.md
```

---

# Prerequisites

Install:

```bash
brew install helm
```

Verify:

```bash
helm version
```

Expected:

```text
version.BuildInfo{Version:"v3.x.x"}
```

---

# Step 1 — Create Helm Chart

Create chart:

```bash
helm create payment-service
```

Generated structure:

```text
payment-service/
├── Chart.yaml
├── values.yaml
├── charts/
└── templates/
    ├── deployment.yaml
    ├── service.yaml
    ├── ingress.yaml
    ├── hpa.yaml
    ├── serviceaccount.yaml
    └── tests/
```

Remove unnecessary files:

```bash
rm -rf templates/tests
rm templates/serviceaccount.yaml
rm templates/NOTES.txt
```

---

# Step 2 — Configure Chart.yaml

Edit:

```yaml
apiVersion: v2
name: payment-service
description: Production Ready Payment Service
type: application

version: 1.0.0
appVersion: "1.0.0"
```

Verify:

```bash
cat Chart.yaml
```

---

# Step 3 — Build Values Structure

Create:

```yaml
replicaCount: 2

image:
  repository: nginx
  tag: latest
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
  DB_PASSWORD: changeme

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

Save as:

```text
values.yaml
```

---

# Step 4 — Create ConfigMap Template

File:

```text
templates/configmap.yaml
```

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .Release.Name }}-config

data:
  APP_ENV: {{ .Values.config.APP_ENV | quote }}
  LOG_LEVEL: {{ .Values.config.LOG_LEVEL | quote }}
```

Render:

```bash
helm template payment-service .
```

Verify ConfigMap appears.

---

# Step 5 — Create Secret Template

File:

```text
templates/secret.yaml
```

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: {{ .Release.Name }}-secret

type: Opaque

stringData:
  DB_PASSWORD: {{ .Values.secret.DB_PASSWORD | quote }}
```

Render:

```bash
helm template payment-service .
```

Verify:

```yaml
kind: Secret
```

appears.

---

# Step 6 — Build Deployment Template

Edit:

```text
templates/deployment.yaml
```

Important sections:

```yaml
replicas: {{ .Values.replicaCount }}
```

---

Container Image:

```yaml
image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
```

---

Resources:

```yaml
resources:
{{- toYaml .Values.resources | nindent 12 }}
```

---

ConfigMap:

```yaml
envFrom:
  - configMapRef:
      name: {{ .Release.Name }}-config
```

---

Secret:

```yaml
envFrom:
  - secretRef:
      name: {{ .Release.Name }}-secret
```

---

Render:

```bash
helm template payment-service .
```

---

# Step 7 — Create Service

File:

```text
templates/service.yaml
```

```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}

spec:
  selector:
    app.kubernetes.io/name: {{ .Chart.Name }}

  ports:
    - port: {{ .Values.service.port }}

  type: {{ .Values.service.type }}
```

Verify:

```bash
helm template payment-service .
```

---

# Step 8 — Create Ingress

File:

```text
templates/ingress.yaml
```

```yaml
{{- if .Values.ingress.enabled }}

apiVersion: networking.k8s.io/v1
kind: Ingress

metadata:
  name: {{ .Release.Name }}

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
                  number: 80

{{- end }}
```

Test:

```bash
helm template payment-service .
```

No ingress should appear because:

```yaml
enabled: false
```

---

Enable:

```yaml
ingress:
  enabled: true
```

Render again.

Ingress should appear.

---

# Step 9 — Create HPA

File:

```text
templates/hpa.yaml
```

```yaml
{{- if .Values.autoscaling.enabled }}

apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler

metadata:
  name: {{ .Release.Name }}

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

Verify:

```bash
helm template payment-service .
```

---

# Step 10 — Environment Files

## values-dev.yaml

```yaml
replicaCount: 1

config:
  APP_ENV: dev

resources:
  requests:
    cpu: 100m
    memory: 128Mi

ingress:
  enabled: false
```

---

## values-qa.yaml

```yaml
replicaCount: 2

config:
  APP_ENV: qa

ingress:
  enabled: true
  host: qa.example.com
```

---

## values-prod.yaml

```yaml
replicaCount: 5

config:
  APP_ENV: prod

ingress:
  enabled: true
  host: prod.example.com

autoscaling:
  enabled: true
  minReplicas: 5
  maxReplicas: 20

resources:
  requests:
    cpu: 500m
    memory: 512Mi

  limits:
    cpu: 2
    memory: 2Gi
```

---

# Step 11 — Test Each Environment

DEV

```bash
helm template payment-service . \
-f values-dev.yaml
```

---

QA

```bash
helm template payment-service . \
-f values-qa.yaml
```

---

PROD

```bash
helm template payment-service . \
-f values-prod.yaml
```

Observe:

```text
Replica count changes
Ingress changes
Resources change
HPA appears
```

---

# Step 12 — Lint Chart

```bash
helm lint .
```

Expected:

```text
1 chart(s) linted, 0 chart(s) failed
```

---

# Step 13 — Package Chart

```bash
helm package .
```

Expected:

```text
payment-service-1.0.0.tgz
```

---

# Step 14 — Install Locally

If using Docker Desktop Kubernetes:

```bash
kubectl config current-context
```

Expected:

```text
docker-desktop
```

Install:

```bash
helm install payment-service . \
-f values-dev.yaml
```

Verify:

```bash
kubectl get all
```

---

# Step 15 — Upgrade Test

Change:

```yaml
replicaCount: 3
```

Upgrade:

```bash
helm upgrade payment-service . \
-f values-dev.yaml
```

Verify:

```bash
kubectl get deploy
```

Expected:

```text
READY 3/3
```

---

# Step 16 — Uninstall

```bash
helm uninstall payment-service
```

Verify:

```bash
kubectl get all
```

Resources removed.

---

# Final Directory Structure

```text
payment-service/
│
├── Chart.yaml
├── values.yaml
├── values-dev.yaml
├── values-qa.yaml
├── values-prod.yaml
│
├── templates/
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── ingress.yaml
│   ├── hpa.yaml
│   ├── configmap.yaml
│   └── secret.yaml
│
└── README.md
```

---

# Expected Interview Explanation

> "I would build a reusable Helm chart by parameterizing replicas, resources, ConfigMaps, Secrets, Ingress, and HPA through values.yaml. Environment-specific configurations are separated into values-dev.yaml, values-qa.yaml, and values-prod.yaml. The chart remains identical across environments while only the values files change. Before deployment I would validate using helm lint and helm template, then package and deploy using helm install or helm upgrade. This approach provides reusability, consistency, and GitOps-friendly configuration management."
