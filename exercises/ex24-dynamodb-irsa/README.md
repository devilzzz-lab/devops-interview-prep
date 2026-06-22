# Exercise 24: DynamoDB Application Deployment

> Deploy a service on Kubernetes that reads, writes, and updates customers in DynamoDB — with zero AWS Access Keys. Auth handled entirely via IRSA (IAM Roles for Service Accounts).

---

## Folder structure

```
exercises/ex24-dynamodb-irsa/
├── app/
│   ├── app.py
│   └── requirements.txt
├── Dockerfile
├── k8s/
│   ├── deployment.yaml
│   └── serviceaccount.yaml
├── iam/
│   └── dynamodb-policy.json
└── scripts/
    ├── setup-irsa.sh
    └── test-api.sh
```

---

## Step 1 — Create the folder structure

```bash
mkdir -p exercises/ex24-dynamodb-irsa/app
mkdir -p exercises/ex24-dynamodb-irsa/k8s
mkdir -p exercises/ex24-dynamodb-irsa/iam
mkdir -p exercises/ex24-dynamodb-irsa/scripts

cd exercises/ex24-dynamodb-irsa
```

---

## Step 2 — Create the DynamoDB table

```bash
aws dynamodb create-table \
  --table-name Customers \
  --attribute-definitions AttributeName=customerId,AttributeType=S \
  --key-schema AttributeName=customerId,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

Wait for it to become ACTIVE:

```bash
aws dynamodb wait table-exists --table-name Customers --region us-east-1
aws dynamodb describe-table --table-name Customers --query 'Table.TableStatus'
```

Expected:

```text
"ACTIVE"
```

---

## Step 3 — Write the Python app

### app/requirements.txt

```text
flask==3.0.0
boto3==1.34.0
```

### app/app.py

```python
import os
import boto3
from flask import Flask, request, jsonify

app = Flask(__name__)

TABLE_NAME = os.environ.get("DYNAMODB_TABLE", "Customers")
REGION     = os.environ.get("AWS_REGION", "us-east-1")

# boto3 picks up credentials automatically from IRSA — no keys needed
dynamodb = boto3.resource("dynamodb", region_name=REGION)
table    = dynamodb.Table(TABLE_NAME)


# ── Write Customer ────────────────────────────────────────
@app.route("/customers", methods=["POST"])
def write_customer():
    data = request.get_json()
    if not data.get("customerId"):
        return jsonify({"error": "customerId is required"}), 400

    table.put_item(Item=data)
    return jsonify({"message": "Customer created", "customerId": data["customerId"]}), 201


# ── Read Customer ─────────────────────────────────────────
@app.route("/customers/<customer_id>", methods=["GET"])
def read_customer(customer_id):
    response = table.get_item(Key={"customerId": customer_id})
    item = response.get("Item")
    if not item:
        return jsonify({"error": "Customer not found"}), 404

    return jsonify(item), 200


# ── Update Customer ───────────────────────────────────────
@app.route("/customers/<customer_id>", methods=["PATCH"])
def update_customer(customer_id):
    data = request.get_json()
    if not data:
        return jsonify({"error": "No fields to update"}), 400

    # Build update expression dynamically from request body
    update_expr   = "SET " + ", ".join(f"#{k} = :{k}" for k in data)
    expr_names    = {f"#{k}": k for k in data}
    expr_values   = {f":{k}": v for k, v in data.items()}

    response = table.update_item(
        Key={"customerId": customer_id},
        UpdateExpression=update_expr,
        ExpressionAttributeNames=expr_names,
        ExpressionAttributeValues=expr_values,
        ReturnValues="ALL_NEW",
    )
    return jsonify(response["Attributes"]), 200


# ── Health check ──────────────────────────────────────────
@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "ok"}), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
```

---

## Step 4 — Write the Dockerfile

```dockerfile
FROM python:3.11-slim

WORKDIR /app

COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/app.py .

EXPOSE 8080

CMD ["python", "app.py"]
```

---

## Step 5 — Build and push Docker image

```bash
# Replace with your ECR or Docker Hub repo
IMAGE="<your-ecr-or-dockerhub>/dynamodb-app:v1"

docker build -t ${IMAGE} .
docker push ${IMAGE}
```

---

## Step 6 — Create the IAM policy for DynamoDB

### iam/dynamodb-policy.json

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:UpdateItem",
        "dynamodb:DescribeTable"
      ],
      "Resource": "arn:aws:dynamodb:us-east-1:<your-account-id>:table/Customers"
    }
  ]
}
```

Create the policy in AWS:

```bash
aws iam create-policy \
  --policy-name DynamoDBCustomersPolicy \
  --policy-document file://iam/dynamodb-policy.json
```

Note the ARN from the output — you'll need it in the next step:

```text
arn:aws:iam::<your-account-id>:policy/DynamoDBCustomersPolicy
```

---

## Step 7 — Set up IRSA

### scripts/setup-irsa.sh

```bash
#!/bin/bash
set -euo pipefail

# ── Variables — fill these in ────────────────────────────
CLUSTER_NAME="<your-eks-cluster>"
REGION="us-east-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
NAMESPACE="default"
SERVICE_ACCOUNT="dynamodb-app-sa"
POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/DynamoDBCustomersPolicy"
ROLE_NAME="dynamodb-app-irsa-role"

echo "Account ID: ${ACCOUNT_ID}"

# ── Step 1: Enable OIDC provider on the cluster ──────────
echo "--> Associating OIDC provider..."
eksctl utils associate-iam-oidc-provider \
  --cluster "${CLUSTER_NAME}" \
  --region "${REGION}" \
  --approve

# ── Step 2: Create IAM role + attach policy ──────────────
echo "--> Creating IAM service account..."
eksctl create iamserviceaccount \
  --cluster "${CLUSTER_NAME}" \
  --namespace "${NAMESPACE}" \
  --name "${SERVICE_ACCOUNT}" \
  --attach-policy-arn "${POLICY_ARN}" \
  --role-name "${ROLE_NAME}" \
  --region "${REGION}" \
  --approve \
  --override-existing-serviceaccounts

echo "==> IRSA setup complete!"

# ── Verify ───────────────────────────────────────────────
echo "--> Verifying service account annotation..."
kubectl get serviceaccount "${SERVICE_ACCOUNT}" -n "${NAMESPACE}" -o yaml \
  | grep "eks.amazonaws.com/role-arn"
```

Run it:

```bash
chmod +x scripts/setup-irsa.sh
./scripts/setup-irsa.sh
```

Expected annotation on the service account:

```text
eks.amazonaws.com/role-arn: arn:aws:iam::<account-id>:role/dynamodb-app-irsa-role
```

---

## Step 8 — Write Kubernetes manifests

### k8s/serviceaccount.yaml

> This is auto-created by eksctl above — keep this file for reference / re-apply if needed.

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: dynamodb-app-sa
  namespace: default
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::<your-account-id>:role/dynamodb-app-irsa-role
```

### k8s/deployment.yaml

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: dynamodb-app
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels:
      app: dynamodb-app
  template:
    metadata:
      labels:
        app: dynamodb-app
    spec:
      serviceAccountName: dynamodb-app-sa   # <-- this is what links the pod to IRSA
      containers:
        - name: dynamodb-app
          image: <your-ecr-or-dockerhub>/dynamodb-app:v1
          ports:
            - containerPort: 8080
          env:
            - name: DYNAMODB_TABLE
              value: "Customers"
            - name: AWS_REGION
              value: "us-east-1"
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
          readinessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: dynamodb-app
  namespace: default
spec:
  selector:
    app: dynamodb-app
  ports:
    - port: 80
      targetPort: 8080
  type: ClusterIP
```

---

## Step 9 — Deploy to Kubernetes

```bash
kubectl apply -f k8s/serviceaccount.yaml
kubectl apply -f k8s/deployment.yaml
```

Verify pods are running:

```bash
kubectl get pods -l app=dynamodb-app
```

Expected:

```text
NAME                            READY   STATUS    RESTARTS
dynamodb-app-xxxxxxxxx-xxxxx    1/1     Running   0
dynamodb-app-xxxxxxxxx-yyyyy    1/1     Running   0
```

---

## Step 10 — Test the API (Demonstrate all 3 operations)

### scripts/test-api.sh

```bash
#!/bin/bash
set -euo pipefail

# Port forward in background
kubectl port-forward svc/dynamodb-app 8080:80 &
PF_PID=$!
sleep 2

BASE="http://localhost:8080"

echo "============================================"
echo " 1. WRITE CUSTOMER"
echo "============================================"
curl -s -X POST "${BASE}/customers" \
  -H "Content-Type: application/json" \
  -d '{
    "customerId": "cust-001",
    "name": "Alice Smith",
    "email": "alice@example.com",
    "plan": "basic"
  }' | jq .

echo ""
echo "============================================"
echo " 2. READ CUSTOMER"
echo "============================================"
curl -s "${BASE}/customers/cust-001" | jq .

echo ""
echo "============================================"
echo " 3. UPDATE CUSTOMER"
echo "============================================"
curl -s -X PATCH "${BASE}/customers/cust-001" \
  -H "Content-Type: application/json" \
  -d '{
    "plan": "premium",
    "email": "alice.smith@example.com"
  }' | jq .

echo ""
echo "============================================"
echo " 4. READ AGAIN — verify update"
echo "============================================"
curl -s "${BASE}/customers/cust-001" | jq .

# Cleanup port-forward
kill $PF_PID
```

Run it:

```bash
chmod +x scripts/test-api.sh
./scripts/test-api.sh
```

Expected output:

```text
============================================
 1. WRITE CUSTOMER
============================================
{
  "message": "Customer created",
  "customerId": "cust-001"
}

============================================
 2. READ CUSTOMER
============================================
{
  "customerId": "cust-001",
  "name": "Alice Smith",
  "email": "alice@example.com",
  "plan": "basic"
}

============================================
 3. UPDATE CUSTOMER
============================================
{
  "customerId": "cust-001",
  "name": "Alice Smith",
  "email": "alice.smith@example.com",
  "plan": "premium"
}

============================================
 4. READ AGAIN — verify update
============================================
{
  "customerId": "cust-001",
  "name": "Alice Smith",
  "email": "alice.smith@example.com",
  "plan": "premium"
}
```

---

## Step 11 — Verify IRSA is working (no keys anywhere)

```bash
# Confirm NO AWS credentials are in the pod env
kubectl exec -it deploy/dynamodb-app -- env | grep -i aws

# You should see these injected by IRSA — NOT static keys:
# AWS_ROLE_ARN=arn:aws:iam::<account-id>:role/dynamodb-app-irsa-role
# AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/serviceaccount/token
# AWS_REGION=us-east-1

# No AWS_ACCESS_KEY_ID — no AWS_SECRET_ACCESS_KEY
```

---

## Step 12 — Commit and push

```bash
git add exercises/ex24-dynamodb-irsa/
git commit -m "ex24: DynamoDB CRUD app with IRSA — no static keys"
git push origin main
```

---

## How IRSA works (the full picture)

```
Pod starts
  → uses serviceAccountName: dynamodb-app-sa
  → SA is annotated with IAM Role ARN

EKS injects into the pod:
  → AWS_ROLE_ARN
  → AWS_WEB_IDENTITY_TOKEN_FILE (a projected K8s token)

boto3 (AWS SDK) sees these env vars automatically
  → calls STS AssumeRoleWithWebIdentity
  → gets temporary credentials (rotated automatically)
  → makes DynamoDB API calls with those temp creds

Result: Zero static keys. Zero secrets. Fully automated.
```

---

## Key concepts to explain in interview

| Concept                         | What it does                                                                 |
| ------------------------------- | ---------------------------------------------------------------------------- |
| IRSA                            | Links a K8s Service Account to an IAM Role via OIDC — no static keys needed |
| OIDC Provider                   | EKS issues tokens that AWS STS can verify and trust                          |
| `serviceAccountName` in pod spec | This is the only thing that connects the pod to the IAM role                |
| `AssumeRoleWithWebIdentity`     | STS exchange — K8s token → temporary AWS credentials (auto-rotated)          |
| Least privilege IAM policy      | Only GetItem, PutItem, UpdateItem on the specific table — nothing else       |
| boto3 credential chain          | SDK picks up IRSA creds automatically — no code changes needed               |

---

## Interview answer (say this)

"I deployed a Flask app on EKS that does read, write, and update on a DynamoDB Customers table — with zero AWS access keys anywhere. Auth is handled entirely through IRSA — IAM Roles for Service Accounts. The way it works is: I created an IAM role with a least-privilege policy scoped to just the Customers table, then used eksctl to create a Kubernetes Service Account annotated with that role's ARN. When the pod starts, EKS automatically injects the role ARN and a web identity token into the pod's environment. boto3 picks those up through its credential chain and calls STS AssumeRoleWithWebIdentity to get temporary, auto-rotating credentials. No secrets, no key rotation headaches, fully auditable through CloudTrail."