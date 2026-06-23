# Exercise 20: External Secrets Integration

> Integrate AWS Secrets Manager with Kubernetes using External Secrets Operator (ESO) on a local kind cluster. ESO pulls secrets from AWS and automatically creates Kubernetes Secrets.

---

## How it works

```
AWS Secrets Manager
        │
        │  (ESO polls every 1h)
        ▼
External Secrets Operator (running in kind)
        │
        │  creates/syncs automatically
        ▼
  Kubernetes Secret
        │
        ▼
   Your Pod / App
```

---

## Folder structure

```
exercises/ex20-external-secrets/
├── k8s/
│   ├── secret-store.yaml
│   └── external-secret.yaml
└── scripts/
    ├── setup-aws-secrets.sh
    └── validate.sh
```

---

## Step 1 — Create the folder structure

```bash
mkdir -p exercises/ex20-external-secrets/k8s
mkdir -p exercises/ex20-external-secrets/scripts

cd exercises/ex20-external-secrets
```

---

## Step 2 — Store secrets in AWS Secrets Manager

### scripts/setup-aws-secrets.sh

```bash
#!/bin/bash
set -euo pipefail

REGION="us-east-1"
SECRET_NAME="ex20/app/secrets"

echo "==> Creating secret in AWS Secrets Manager..."

aws secretsmanager create-secret \
  --name "${SECRET_NAME}" \
  --region "${REGION}" \
  --secret-string '{
    "DB_USERNAME": "admin",
    "DB_PASSWORD": "SuperSecurePass123!",
    "JWT_SECRET": "myjwtsecretkey-do-not-expose"
  }'

echo "==> Secret created!"
echo "--> Verifying..."

aws secretsmanager get-secret-value \
  --secret-id "${SECRET_NAME}" \
  --region "${REGION}" \
  --query 'SecretString' \
  --output text | jq .
```

Run it:

```bash
chmod +x scripts/setup-aws-secrets.sh
./scripts/setup-aws-secrets.sh
```

Expected output:

```json
{
  "DB_USERNAME": "admin",
  "DB_PASSWORD": "SuperSecurePass123!",
  "JWT_SECRET": "myjwtsecretkey-do-not-expose"
}
```

---

## Step 3 — Switch to kind cluster

```bash
kubectl config use-context kind-<your-cluster-name>

# Verify
kubectl cluster-info
kubectl get nodes
```

Expected:

```text
NAME                 STATUS   ROLES           AGE
kind-control-plane   Ready    control-plane   Xm
```

---

## Step 4 — Install External Secrets Operator via Helm

```bash
# Add the ESO helm repo
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

# Install ESO into its own namespace
helm install external-secrets \
  external-secrets/external-secrets \
  --namespace external-secrets \
  --create-namespace \
  --wait
```

Verify ESO pods are running:

```bash
kubectl get pods -n external-secrets
```

Expected:

```text
NAME                                                READY   STATUS
external-secrets-xxxxxxxxx                          1/1     Running
external-secrets-cert-controller-xxxxxxxxx          1/1     Running
external-secrets-webhook-xxxxxxxxx                  1/1     Running
```

---

## Step 5 — Create a Kubernetes Secret with AWS credentials

> This is how ESO authenticates to AWS from inside kind. On EKS you'd use IRSA — on kind we use a credentials secret.

```bash
kubectl create secret generic aws-credentials \
  --namespace default \
  --from-literal=access-key=$(aws configure get aws_access_key_id) \
  --from-literal=secret-access-key=$(aws configure get aws_secret_access_key)
```

Verify:

```bash
kubectl get secret aws-credentials -n default
```

Expected:

```text
NAME               TYPE     DATA   AGE
aws-credentials    Opaque   2      5s
```

---

## Step 6 — Create the SecretStore

The `SecretStore` tells ESO **how to connect to AWS** and **which region** to use.

### k8s/secret-store.yaml

Apply it:

```bash
kubectl apply -f k8s/secret-store.yaml
```

Verify the SecretStore is ready:

```bash
kubectl get secretstore -n default
```

Expected:

```text
NAME               AGE   STATUS   CAPABILITIES   READY
aws-secret-store   10s   Valid    ReadWrite      True
```

---

## Step 7 — Create the ExternalSecret

The `ExternalSecret` tells ESO **which secret to fetch** from AWS and **what to name the K8s Secret**.

### k8s/external-secret.yaml

Apply it:

```bash
kubectl apply -f k8s/external-secret.yaml
```

---

## Step 8 — Validate (the required checks)

### scripts/validate.sh

Run it:

```bash
chmod +x scripts/validate.sh
./scripts/validate.sh
```

Expected output:

```text
============================================
 1. kubectl get externalsecret
============================================
NAME                  STORE              REFRESH INTERVAL   STATUS         READY
app-external-secret   aws-secret-store   1h                 SecretSynced   True

============================================
 2. kubectl get secret
============================================
NAME         TYPE     DATA   AGE
app-secret   Opaque   3      30s

============================================
 3. ExternalSecret detailed status
============================================
Status:
  Conditions:
    Message: Secret was synced
    Reason:  SecretSynced
    Status:  True
    Type:    Ready

============================================
 4. Decode and verify secret values
============================================
DB_USERNAME : admin
DB_PASSWORD : SuperSecurePass123!
JWT_SECRET  : myjwtsecretkey-do-not-expose
```

---

## Step 9 — Bonus: Use the secret in a pod

This proves the K8s Secret works end-to-end in a real pod:

Apply it:

```bash
kubectl apply -f k8s/test-pod.yaml
```

Expected:

```text
DB_USERNAME=admin | DB_PASSWORD=SuperSecurePass123! | JWT_SECRET=myjwtsecretkey-do-not-expose
```

---

## Step 10 — Test auto-sync (update secret in AWS, K8s updates too)

Expected:

```text
NewPassword456!
```

K8s secret updated automatically — no manual kubectl apply needed.

---

## Step 11 — Commit and push

```bash
git add exercises/ex20-external-secrets/
git commit -m "ex20: external secrets integration with AWS Secrets Manager"
git push origin main
```

---

## Key concepts to explain in interview

| Concept | What it does |
|---|---|
| `SecretStore` | Defines HOW to connect to the secret provider (AWS, region, auth) |
| `ExternalSecret` | Defines WHAT to fetch and what K8s Secret to create |
| `refreshInterval` | ESO re-syncs automatically — K8s secret stays in sync with AWS |
| `creationPolicy: Owner` | ESO owns the K8s Secret — cleans it up if ExternalSecret is deleted |
| `property` field | Extracts a specific key from a JSON secret in AWS |
| Force sync annotation | Triggers immediate re-sync without waiting for refresh interval |
| On EKS | Replace `aws-credentials` secret with IRSA — zero static keys |

---

## Interview answer (say this)

"I integrated AWS Secrets Manager with Kubernetes using the External Secrets Operator. I stored DB_USERNAME, DB_PASSWORD, and JWT_SECRET as a single JSON secret in AWS Secrets Manager. Then I deployed ESO via Helm, created a SecretStore that tells ESO how to authenticate to AWS, and created an ExternalSecret that maps each JSON field to a key in a Kubernetes Secret. ESO automatically creates and syncs the K8s Secret — if I update the value in AWS, ESO picks it up on the next refresh cycle, or I can force an immediate sync with an annotation. On a kind cluster I used an AWS credentials secret for auth — on EKS this would be replaced with IRSA so there are zero static keys anywhere."

---

## Fix: CRDs not found after Helm install

If you see:
```text
no matches for kind "SecretStore" in version "external-secrets.io/v1beta1"
ensure CRDs are installed first
```

Run this:

```bash
# Reinstall ESO with CRDs explicitly enabled
helm upgrade --install external-secrets \
  external-secrets/external-secrets \
  --namespace external-secrets \
  --create-namespace \
  --set installCRDs=true \
  --wait
```

Verify CRDs are now present:

```bash
kubectl get crds | grep external-secrets
```

Expected:

```text
externalsecrets.external-secrets.io
secretstores.external-secrets.io
clustersecretstores.external-secrets.io
...
```

Then re-apply:

```bash
kubectl apply -f k8s/secret-store.yaml
kubectl apply -f k8s/external-secret.yaml
```

---

## Fix: apiVersion v1beta1 → v1 (newer ESO versions)

If you see:
```text
no matches for kind "SecretStore" in version "external-secrets.io/v1beta1"
```

Check what version your ESO uses:
```bash
kubectl api-resources | grep external-secrets
# Look at the VERSION column — if it shows v1 not v1beta1, run the fix below
```

Fix both files in one shot:
```bash
sed -i '' 's|external-secrets.io/v1beta1|external-secrets.io/v1|g' k8s/secret-store.yaml
sed -i '' 's|external-secrets.io/v1beta1|external-secrets.io/v1|g' k8s/external-secret.yaml

# Verify
head -3 k8s/secret-store.yaml
head -3 k8s/external-secret.yaml
```

Then re-apply:
```bash
kubectl apply -f k8s/secret-store.yaml
kubectl apply -f k8s/external-secret.yaml
```
