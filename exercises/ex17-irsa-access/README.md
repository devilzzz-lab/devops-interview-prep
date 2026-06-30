# Exercise 17 – Implement IRSA for Application Access

> **Important — this exercise needs real AWS, not your kind cluster**

---

# Step 1 — Create a test DynamoDB table (free, real AWS)

```bash
aws dynamodb create-table \
  --table-name customer-data \
  --attribute-definitions AttributeName=id,AttributeType=S \
  --key-schema AttributeName=id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region ap-south-1
```

Expected:

```json
{
  "TableDescription": {
    "TableName": "customer-data",
    "TableStatus": "CREATING"
  }
}
```

Verify it's active:

```bash
aws dynamodb describe-table \
  --table-name customer-data \
  --region ap-south-1 \
  --query "Table.TableStatus"
```

Expected:

```text
"ACTIVE"
```

DynamoDB on-demand billing has a generous free tier — this costs effectively nothing for testing.

---

# Step 2 — Create the IAM Policy (GetItem, PutItem, UpdateItem)

```bash
cat > dynamodb-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:UpdateItem"
      ],
      "Resource": "arn:aws:dynamodb:ap-south-1:123456789012:table/customer-data"
    }
  ]
}
EOF

aws iam create-policy \
  --policy-name payment-dynamodb-policy \
  --policy-document file://dynamodb-policy.json
```

Expected — copy the ARN:

```json
{
  "Policy": {
    "PolicyName": "payment-dynamodb-policy",
    "Arn": "arn:aws:iam::123456789012:policy/payment-dynamodb-policy"
  }
}
```

---

# Step 3 — Create the OIDC Provider (EKS-only — this requires a real cluster)

If you have an actual EKS cluster:

```bash
eksctl utils associate-iam-oidc-provider \
  --cluster my-cluster \
  --region ap-south-1 \
  --approve
```

Expected:

```text
created IAM Open ID Connect provider for cluster "my-cluster"
```

Without a real EKS cluster, you can still get the OIDC URL format right for the trust policy by knowing the pattern:

```text
arn:aws:iam::<account-id>:oidc-provider/oidc.eks.<region>.amazonaws.com/id/<oidc-id>
```

---

# Step 4 — Create the IAM Role with trust policy

```bash
cat > trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::123456789012:oidc-provider/oidc.eks.ap-south-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B716D3041E"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.ap-south-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B716D3041E:sub": "system:serviceaccount:default:payment-service-sa",
          "oidc.eks.ap-south-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B716D3041E:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF

aws iam create-role \
  --role-name payment-irsa-role \
  --assume-role-policy-document file://trust-policy.json
```

Expected — copy the ARN:

```json
{
  "Role": {
    "RoleName": "payment-irsa-role",
    "Arn": "arn:aws:iam::123456789012:role/payment-irsa-role"
  }
}
```

Attach the policy:

```bash
aws iam attach-role-policy \
  --role-name payment-irsa-role \
  --policy-arn arn:aws:iam::123456789012:policy/payment-dynamodb-policy
```

---

# Step 5 — Create the Kubernetes ServiceAccount

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: payment-service-sa
  namespace: default
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/payment-irsa-role
```

```bash
kubectl apply -f serviceaccount.yaml
```

You CAN run this on kind — it just won't actually authenticate to AWS without a real OIDC trust relationship. The manifest itself is valid and testable.

---

# Step 6 — Deploy a test pod using the ServiceAccount

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: dynamodb-test
  namespace: default
spec:
  serviceAccountName: payment-service-sa
  containers:
    - name: aws-cli
      image: amazon/aws-cli:latest
      command: ["sleep", "3600"]
```

```bash
kubectl apply -f test-pod.yaml
```

---

# Step 7 — Test GetItem, PutItem, UpdateItem from inside the pod

*(Only works for real on actual EKS with IRSA configured — shown here as the verification step you'd run.)*

### PutItem — create a record

```bash
kubectl exec -it dynamodb-test -- aws dynamodb put-item \
  --table-name customer-data \
  --item '{"id": {"S": "cust-001"}, "name": {"S": "Sujith"}}' \
  --region ap-south-1
```

Expected:

```text
(no output = success)
```

---

### GetItem — read it back

```bash
kubectl exec -it dynamodb-test -- aws dynamodb get-item \
  --table-name customer-data \
  --key '{"id": {"S": "cust-001"}}' \
  --region ap-south-1
```

Expected:

```json
{
  "Item": {
    "id": {
      "S": "cust-001"
    },
    "name": {
      "S": "Sujith"
    }
  }
}
```

---

### UpdateItem — modify it

```bash
kubectl exec -it dynamodb-test -- aws dynamodb update-item \
  --table-name customer-data \
  --key '{"id": {"S": "cust-001"}}' \
  --update-expression "SET #n = :newname" \
  --expression-attribute-names '{"#n": "name"}' \
  --expression-attribute-values '{":newname": {"S": "Sujith Updated"}}' \
  --region ap-south-1
```

Expected:

```text
(no output = success)
```

---

### Verify the update

```bash
kubectl exec -it dynamodb-test -- aws dynamodb get-item \
  --table-name customer-data \
  --key '{"id": {"S": "cust-001"}}' \
  --region ap-south-1
```

Expected:

```json
{
  "Item": {
    "id": {
      "S": "cust-001"
    },
    "name": {
      "S": "Sujith Updated"
    }
  }
}
```

---

# Step 8 — Verify NO access keys were used anywhere

This is the actual point of IRSA — prove zero hardcoded credentials.

```bash
kubectl exec -it dynamodb-test -- env | grep -i AWS
```

Expected (on real EKS with IRSA working):

```text
AWS_ROLE_ARN=arn:aws:iam::123456789012:role/payment-irsa-role
AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/serviceaccount/token
```

Notice:

- No `AWS_ACCESS_KEY_ID`
- No `AWS_SECRET_ACCESS_KEY`

That's the proof.

---

# Cleanup

```bash
kubectl delete pod dynamodb-test

kubectl delete serviceaccount payment-service-sa

aws dynamodb delete-table \
  --table-name customer-data \
  --region ap-south-1

aws iam detach-role-policy \
  --role-name payment-irsa-role \
  --policy-arn arn:aws:iam::123456789012:policy/payment-dynamodb-policy

aws iam delete-role \
  --role-name payment-irsa-role

aws iam delete-policy \
  --policy-arn arn:aws:iam::123456789012:policy/payment-dynamodb-policy
```

---

# Interview answer (say this)

> "I implemented IRSA by first associating an OIDC identity provider with the EKS cluster, which lets AWS IAM trust tokens issued by Kubernetes. I created a scoped IAM policy allowing only GetItem, PutItem, and UpdateItem on the specific DynamoDB table, then an IAM role with a trust policy that only allows the role to be assumed by a specific Kubernetes ServiceAccount in a specific namespace, verified through the OIDC sub claim. The ServiceAccount in Kubernetes is annotated with that role's ARN, and any pod using that ServiceAccount automatically gets a projected token mounted, which the AWS SDK exchanges for temporary credentials via AssumeRoleWithWebIdentity. I verified it worked end to end by running GetItem, PutItem, and UpdateItem from inside the pod, and confirmed there were zero AWS access keys anywhere in the pod's environment, only the role ARN and the web identity token file path — proving credentials are fully dynamic and short-lived rather than long-lived static keys."