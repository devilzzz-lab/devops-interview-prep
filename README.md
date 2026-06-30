# DevOps Interview Prep
Production-grade EKS/AWS troubleshooting exercises and answer guides.
> Focused on: IAM/IRSA, ArgoCD, Helm, Kubernetes incidents, Observability, Secrets Management

---

## Exercise Index

| # | Topic | Type | Status |
|---|-------|------|--------|
| [Ex 02](./exercises/ex02-iam-irsa-failure/) | IAM / IRSA Failure | Troubleshooting | ✅ |
| [Ex 03](./exercises/ex03-argocd-outsync/) | ArgoCD OutOfSync Production | Troubleshooting | ✅ |
| [Ex 04](./exercises/ex04-external-secrets-failure/) | External Secrets Failure | Troubleshooting | ✅ |
| [Ex 05](./exercises/ex05-helm-upgrade-failure/) | Helm Upgrade Failure | Troubleshooting | ✅ |
| [Ex 06](./exercises/ex06-hpa-autoscaler-failure/) | HPA + Cluster Autoscaler Failure | Troubleshooting | ✅ |
| [Ex 07](./exercises/ex07-alb-ingress-failure/) | Kubernetes Ingress + ALB | Troubleshooting | ✅ |
| [Ex 08](./exercises/ex08-egress-failure/) |  Egress Restriction Incident | Troubleshooting | ✅ |
| [Ex 09](./exercises/ex09-prometheus-failure/) | Prometheus Monitoring Failure | Troubleshooting | ✅ |
| [Ex 11](./exercises/ex11-crashloopbackoff/) | CrashLoopBackOff Investigation | Troubleshooting | ✅ |
| [Ex 12](./exercises/ex12-node-notready/) | Node NotReady — DiskPressure | Incident Recovery | ✅ |
| [Ex 13](./exercises/ex13-secret-rotation/) | Secret Rotation Outage | Troubleshooting | ✅ |
| [Ex 14](./exercises/ex14-distributed-tracing/) | Distributed Tracing Investigation | Observability | 🔲 |
| [Ex 15](./exercises/ex15-production-outage-rca/) | Complete Production Outage RCA | Full RCA | ✅ |
| [Ex 18](./exercises/ex18-gitops-argocd/) | GitOps Platform using ArgoCD | Hands-on | ✅ |
| [Ex 19](./exercises/ex19-helm-chart-engineering/) | Helm Chart Engineering | Hands-on | ✅ |
| [Ex 20](./exercises/ex20-external-secrets/) | External Secrets Integration | Hands-on | ✅ |
| [Ex 21](./exercises/ex21-alb-ingress-manifest/) | ALB Ingress Manifest | Hands-on | ✅ |
| [Ex 22](./exercises/ex22-autoscaling/) | HPA + Cluster Autoscaling | Hands-on | ✅ |
| [Ex 24](./exercises/ex24-dynamodb-irsa/) | DynamoDB Application Deployment (IRSA) | Hands-on | ✅ |
| [Ex 25](./exercises/ex25-observability/) | Observability Platform Deployment | Hands-on | ✅ |
| [Ex 26](./exercises/ex26-s3-backup/) | S3 Backup Solution | Hands-on | ✅ |

---

## Key Concepts Covered

- **IRSA** — IAM Roles for Service Accounts (EKS pod-level AWS auth, zero static keys)
- **ArgoCD** — GitOps sync, drift detection, self-heal, auto-prune
- **Helm** — Immutable field errors, chart upgrades, values management
- **External Secrets** — AWS Secrets Manager → Kubernetes Secret sync via ESO
- **HPA + Cluster Autoscaler** — Pod and node scaling failures
- **Prometheus / Grafana** — ServiceMonitor mismatches, missing metrics
- **Loki / Alloy / Tempo** — Log pipeline failures, distributed tracing
- **Secret Rotation** — Propagation gaps between AWS and Kubernetes
- **Node Recovery** — DiskPressure, log cleanup, safe drain
- **DynamoDB** — CRUD app deployment with IRSA auth (no static keys)
- **S3 Backup** — Timestamped backups, restore process, S3 versioning
- **GitOps** — Multi-env folder structure (dev/qa/prod), auto-sync, self-heal

---

## Stack

`EKS` `kind` `ArgoCD` `Helm` `Prometheus` `Grafana` `Loki` `Tempo` `Alloy` `External Secrets Operator` `AWS IAM` `IRSA` `ALB` `DynamoDB` `S3` `Secrets Manager`