# Exercise 10 – Loki Logging Failure (HTTP 403 Authentication Error)

The diagram tells the story immediately — Application and Alloy's read side are fine. The break is specifically at Alloy's push to Loki. Let's trace it properly.

---

# Why this narrows it down fast

Alloy logs say:

> "failed to push logs, HTTP 403"

→ Alloy tried, got rejected

Loki logs say:

> "authentication failed"

→ Loki rejected the request

Both sides agree → this is an **AUTH** problem between Alloy and Loki specifically.

- NOT a network problem (network issue would be timeout, not 403)
- NOT an application problem (app never talks to Loki directly)

**403 = "I see your request, I'm refusing it."**

That's always an auth/permissions issue, never a connectivity issue.

---

# Step 1 — Confirm the failure point from both sides

```bash
# Check Alloy logs for the exact error
kubectl logs -l app.kubernetes.io/name=alloy -n monitoring-stack --tail=50 | grep -i "403\|failed to push\|forbidden"
```

Expected:

```text
level=error msg="final error sending batch" status=403 tenant=fake
```

```bash
# Check Loki logs for the auth rejection
kubectl logs loki-0 -n monitoring-stack --tail=50 | grep -i "authentication\|403\|forbidden"
```

Expected:

```text
level=warn msg="POST /loki/api/v1/push (403) ... authentication failed, missing or invalid tenant ID"
```

---

# Step 2 — Understand why Loki is rejecting it

Loki has a setting called **auth_enabled**. When true, every push request MUST include a tenant header (`X-Scope-OrgID`). If Alloy isn't sending that header, or Loki expects auth tokens that Alloy isn't providing, you get exactly this 403.

```bash
# Check Loki's current auth setting
kubectl get configmap loki -n monitoring-stack -o yaml | grep -A2 "auth_enabled"
```

Expected (this is the problem):

```yaml
auth_enabled: true
```

If `auth_enabled: true` but Alloy's config doesn't send a tenant header, every push fails with 403.

---

# Step 3 — Check Alloy's write config for missing auth

```bash
kubectl get configmap alloy -n monitoring-stack -o yaml | grep -A10 "loki.write"
```

Expected (broken — no auth headers):

```hcl
loki.write "local" {
  endpoint {
    url = "http://loki:3100/loki/api/v1/push"
  }
}
```

No `tenant_id` or `basic_auth` block — if Loki requires auth and Alloy doesn't send any, that's your root cause confirmed.

---

# Fix Option A — Disable auth on Loki (correct for local/dev, what we actually did in Ex 25)

```bash
# In loki-values.yaml, this should already be set correctly:
auth_enabled: false
```

If somehow it got set back to true:

```bash
helm upgrade loki grafana/loki \
  --namespace monitoring-stack \
  -f loki-values.yaml \
  --set loki.auth_enabled=false
```

---

# Fix Option B — If auth IS required (production scenario), add tenant ID to Alloy

```hcl
loki.write "local" {
  endpoint {
    url = "http://loki:3100/loki/api/v1/push"
    tenant_id = "fake"
  }
}
```

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
          url       = "http://loki:3100/loki/api/v1/push"
          tenant_id = "fake"
        }
      }
EOF

helm upgrade alloy grafana/alloy \
  --namespace monitoring-stack \
  -f alloy-config.yaml
```

---

# Step 4 — Restart and verify

```bash
kubectl rollout restart daemonset alloy -n monitoring-stack
```

```bash
# Watch Alloy logs — should stop showing 403
kubectl logs -l app.kubernetes.io/name=alloy -n monitoring-stack -f
```

Expected (no more errors):

```text
level=info msg="finished node evaluation" controller_id=loki.write.local
```

```bash
# Confirm Loki is receiving pushes successfully now
kubectl logs loki-0 -n monitoring-stack --tail=20 | grep "POST /loki/api/v1/push"
```

Expected:

```text
msg="POST /loki/api/v1/push (204) ..."
```

A **204** status means success — logs are flowing again.

---

# Step 5 — Confirm in Grafana

Go to **Explore → Loki** → run query:

```text
{namespace="monitoring-stack"}
```

Expected:

Fresh log lines appearing again.

---

# Decision tree for this exercise

| Where the error appears | What it means |
|--------------------------|---------------|
| Application can't reach Alloy | Network/DNS issue between app and Alloy — not this scenario |
| Alloy reads logs fine, push to Loki fails with 403 | Auth mismatch — this scenario |
| Loki receives but query in Grafana shows nothing | Grafana data source misconfigured, not Loki itself |
| Everything connects but no log lines appear | Label/query mismatch, not a failure at all |

---

# Interview answer (say this)

> "A 403 on push, confirmed on both the Alloy side and the Loki side, means this is purely an authentication issue between Alloy and Loki — not a network problem, since a network failure would show as a timeout or connection refused, not a 403. I traced it by checking Alloy's logs for the exact rejection, then Loki's logs to see why it rejected the request, which showed a missing or invalid tenant ID. Loki has an auth_enabled flag, and when true, every push needs an X-Scope-OrgID tenant header. The fix is either disabling auth on Loki for a single-tenant setup, which is what you'd do in dev, or adding a tenant_id to Alloy's loki.write block to match what Loki expects, which is the right approach in a multi-tenant production setup. After the fix, I'd confirm by watching for a 204 success status in Loki's logs instead of 403, then verify the actual log lines show up again in Grafana's Explore view."