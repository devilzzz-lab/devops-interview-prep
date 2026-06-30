# Exercise 25 — Observability Platform Deployment

## Objective

Deploy a full monitoring stack covering metrics, logs, and traces, with dashboards for CPU, memory, error rate, and request rate.

## Components

```
Prometheus  - collects and stores METRICS (CPU, memory, request count)
Grafana     - the dashboard UI, visualizes everything
Loki        - collects and stores LOGS
Alloy       - the agent that ships logs from pods to Loki
Tempo       - collects and stores TRACES (request journey across services)
```

## Architecture

```
payment-service (emits metrics, logs, traces)
    |              |              |
Prometheus       Alloy          Tempo
(scrapes        (tails         (receives
/metrics)       container       traces via
                logs)           OTLP)
    |              |              |
Prometheus       Loki           Tempo
TSDB            (stores         storage
(stores         logs)          (stores
metrics)                       traces)
    |              |              |
    +------------ Grafana --------+
           (queries all 3,
           builds dashboards)
                   |
              Dashboards
        CPU, Memory, Error Rate,
            Request Rate
```

Metrics = numbers over time. Logs = text events. Traces = request journeys.

---

## Prerequisites

```bash
brew install helm kubectl
kubectl config use-context kind-debug-cluster
```

---

## Step 1 — Add Helm repos

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
```

Expected:

```
"prometheus-community" has been added to your repositories
"grafana" has been added to your repositories
Update Complete.
```

---

## Step 2 — Create namespace

```bash
kubectl create namespace monitoring-stack
```

---

## Step 3 — Install Prometheus + Grafana (bundled together)

`kube-prometheus-stack` installs Prometheus AND Grafana together.

```bash
helm install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring-stack \
  --set grafana.adminPassword=admin123
```

Expected:

```
NAME: monitoring
STATUS: deployed
```

Watch pods come up (takes ~2 minutes):

```bash
kubectl get pods -n monitoring-stack -w
```

Expected (all Running):

```
NAME                                                     READY   STATUS
monitoring-grafana-xxxxxxxxx                             3/3     Running
monitoring-kube-prometheus-operator-xxxxxxxxx             1/1     Running
monitoring-kube-state-metrics-xxxxxxxxx                   1/1     Running
monitoring-prometheus-node-exporter-xxxxx                 1/1     Running
prometheus-monitoring-kube-prometheus-prometheus-0         2/2     Running
alertmanager-monitoring-kube-prometheus-alertmanager-0     2/2     Running
```

---

## Step 4 — Install Loki

```bash
helm install loki grafana/loki-stack \
  --namespace monitoring-stack \
  --set grafana.enabled=false \
  --set prometheus.enabled=false
```

Expected:

```
NAME: loki
STATUS: deployed
```

Verify:

```bash
kubectl get pods -n monitoring-stack | grep loki
```

Expected:

```
loki-0                          1/1     Running
loki-promtail-xxxxx             1/1     Running
```

Note: loki-stack ships with Promtail by default. Alloy is added separately in the next step since this exercise specifically asks for Alloy.

---

## Step 5 — Install Alloy (log shipping agent)

```bash
helm install alloy grafana/alloy \
  --namespace monitoring-stack
```

Expected:

```
NAME: alloy
STATUS: deployed
```

Verify:

```bash
kubectl get pods -n monitoring-stack | grep alloy
```

Expected:

```
alloy-xxxxx                     2/2     Running
```

### Configure Alloy to ship logs to Loki

```bash
cat > alloy-config.yaml << 'EOF'
alloy:
  configMap:
    content: |
      discovery.kubernetes "pods" {
        role = "pod"
      }

      discovery.relabel "pod_logs" {
        targets = discovery.kubernetes.pods.targets
        rule {
          source_labels = ["__meta_kubernetes_namespace"]
          target_label  = "namespace"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_name"]
          target_label  = "pod"
        }
      }

      loki.source.kubernetes "pods" {
        targets    = discovery.relabel.pod_logs.output
        forward_to = [loki.write.local.receiver]
      }

      loki.write "local" {
        endpoint {
          url = "http://loki:3100/loki/api/v1/push"
        }
      }
EOF

helm upgrade alloy grafana/alloy \
  --namespace monitoring-stack \
  -f alloy-config.yaml
```

Expected:

```
Release "alloy" has been upgraded.
```

---

## Step 6 — Install Tempo

```bash
helm install tempo grafana/tempo \
  --namespace monitoring-stack
```

Expected:

```
NAME: tempo
STATUS: deployed
```

Verify:

```bash
kubectl get pods -n monitoring-stack | grep tempo
```

Expected:

```
tempo-0                         1/1     Running
```

---

## Step 7 — Verify everything is running

```bash
kubectl get pods -n monitoring-stack
```

Expected, all Running:

```
NAME                                                     READY   STATUS
monitoring-grafana-xxxxxxxxx                             3/3     Running
monitoring-kube-prometheus-operator-xxxxxxxxx             1/1     Running
monitoring-kube-state-metrics-xxxxxxxxx                   1/1     Running
monitoring-prometheus-node-exporter-xxxxx                 1/1     Running
prometheus-monitoring-kube-prometheus-prometheus-0         2/2     Running
loki-0                                                    1/1     Running
loki-promtail-xxxxx                                       1/1     Running
alloy-xxxxx                                               2/2     Running
tempo-0                                                   1/1     Running
```

---

## Step 8 — Access Grafana

```bash
kubectl port-forward svc/monitoring-grafana -n monitoring-stack 3000:80
```

Open browser: `http://localhost:3000`

Login:

```
Username: admin
Password: admin123
```

---

## Step 9 — Connect Loki and Tempo as data sources in Grafana

Prometheus is auto-connected by the Helm chart. Add Loki and Tempo manually.

For Loki:
1. Go to Connections, Data sources, Add data source
2. Select Loki
3. URL: `http://loki:3100`
4. Click Save and test

Expected: `Data source connected and labels found.`

For Tempo:
1. Add data source, select Tempo
2. URL: `http://tempo:3100`
3. Click Save and test

Expected: `Data source connected.`

---

## Step 10 — Verify metrics are flowing

```bash
kubectl port-forward svc/monitoring-kube-prometheus-prometheus -n monitoring-stack 9090:9090
```

Open: `http://localhost:9090`

Run a test query:

```
up
```

Expected: list of all scrape targets showing `1` (healthy).

---

## Step 11 — Verify logs are flowing

In Grafana, go to Explore, select the Loki data source.

Run query:

```
{namespace="monitoring-stack"}
```

Expected: live log lines streaming from your pods.

---

## Step 12 — Create the dashboards (CPU, Memory, Error Rate, Request Rate)

In Grafana: Dashboards, New, New Dashboard, Add visualization, select Prometheus.

### Panel 1 — CPU usage

```promql
sum(rate(container_cpu_usage_seconds_total{namespace="monitoring-stack"}[5m])) by (pod)
```

### Panel 2 — Memory usage

```promql
sum(container_memory_working_set_bytes{namespace="monitoring-stack"}) by (pod)
```

### Panel 3 — Error rate

```promql
sum(rate(http_requests_total{status=~"5.."}[5m])) by (service)
```

### Panel 4 — Request rate

```promql
sum(rate(http_requests_total[5m])) by (service)
```

Note: Panel 3 and 4 require your application to expose an `http_requests_total` metric. If using plain nginx as a test app, these queries return no data unless an nginx exporter is configured. That is fine for now, the panels exist and the query syntax is correct.

Save dashboard as: Application Overview

---

## Step 13 — Import pre-built dashboards (faster, more impressive)

Grafana has ready-made dashboards for Kubernetes. Import instead of building from scratch.

1. Go to Dashboards, Import
2. Enter dashboard ID: `315` (Kubernetes cluster monitoring)
3. Select Prometheus as data source
4. Click Import

Other useful IDs:

```
315   - Kubernetes cluster monitoring (CPU, memory, network)
1860  - Node Exporter Full
13639 - Logs / Loki dashboard
```

---

## Step 14 — Test trace collection (optional, needs app instrumentation)

Tempo requires your app to send traces via OTLP.

```bash
kubectl port-forward svc/tempo -n monitoring-stack 3100:3100
```

Sending a real test trace requires an OTLP client (otel-cli or an instrumented app). Tempo is correctly installed and ready to receive traces even without live data yet.

---

## Cleanup

```bash
helm uninstall monitoring -n monitoring-stack
helm uninstall loki -n monitoring-stack
helm uninstall alloy -n monitoring-stack
helm uninstall tempo -n monitoring-stack
kubectl delete namespace monitoring-stack
```

---

## Key concepts to explain in interview

| Component | Role | Pillar |
|---|---|---|
| Prometheus | Scrapes and stores time-series metrics | Metrics |
| Grafana | Visualization layer, queries all data sources | Dashboards |
| Loki | Stores logs, indexes only labels (cheap) | Logs |
| Alloy | Agent that tails container logs and ships to Loki | Logs |
| Tempo | Stores distributed traces | Traces |

### Why Loki indexes only labels, not full text

Unlike Elasticsearch, Loki does not index the full log line content, only labels like namespace, pod, and app. This makes it far cheaper to run at scale. Full text search happens at query time using grep-style filtering on the labeled stream.

### Why Alloy instead of Promtail

Alloy is Grafana's newer unified collector that can ship logs, metrics, and traces, replacing the need for separate agents like Promtail, Prometheus node exporters, and OTel collectors in many setups.

### The three pillars working together

A real debugging flow: a CPU spike shows up in a Prometheus metric panel. You jump to Loki to see error logs from that exact time window. You then jump to Tempo to see which specific request triggered the spike, end to end across services. This is why all three are connected as data sources in the same Grafana instance.

---

## What you proved in this exercise

```
Prometheus  - collecting metrics from cluster                    done
Grafana     - dashboards built and data sources connected        done
Loki        - log storage running                                done
Alloy       - shipping container logs to Loki                    done
Tempo       - trace storage running                              done
Dashboards  - CPU, Memory, Error Rate, Request Rate panels        done
```

---

## Interview answer (say this)

> "I deployed a full observability stack on Kubernetes using Helm: kube-prometheus-stack for metrics and Grafana, loki-stack for log storage, Alloy as the log shipping agent that tails container logs and forwards them to Loki, and Tempo for distributed trace storage. Grafana is configured with all three as data sources so I can correlate metrics, logs, and traces in one place. For example, seeing a CPU spike in a metric panel, then jumping to Loki to see the error logs from that exact time window, then to Tempo to see which specific request caused it. I built dashboards covering CPU, memory, error rate, and request rate using PromQL queries against container and application metrics."