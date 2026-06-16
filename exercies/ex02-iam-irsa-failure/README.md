# Exercise 2 — IAM / IRSA Failure

## Incident

Application suddenly cannot read DynamoDB.

```
2026-05-10T08:12:13Z ERROR botocore.exceptions.ClientError:
An error occurred (AccessDeniedException) when calling the GetItem operation:
User: arn:aws:sts::123456789012:assumed-role/eks-nodegroup-role
is not authorized to perform: dynamodb:GetItem
on resource: arn:aws:dynamodb:ap-south-1:123456789012:table/customer-data
```

## Architecture (intended)

```
Pod
 └── ServiceAccount (annotated with IAM Role ARN)
      └── OIDC Provider (validates JWT)
           └── Pod-specific IAM Role
                └── DynamoDB
```

## Architecture (broken — what's actually happening)

```
Pod
 └── No ServiceAccount / missing annotation
      └── Falls back to EC2 instance metadata
           └── Node IAM Role (eks-nodegroup-role)
                └── DynamoDB ← AccessDenied (node role has no DynamoDB policy)
```

---

## Root Cause Analysis

### Q1 — Why is the node role being used?

The error ARN `assumed-role/eks-nodegroup-role` tells us the pod is using the **EC2 node's IAM role**, not a pod-level role.

When IRSA is missing or misconfigured, the AWS SDK inside the pod falls back to:
1. Environment variables → not set
2. `~/.aws/credentials` → not present in pod
3. **EC2 Instance Metadata Service (IMDS)** → `http://169.254.169.254/latest/meta-data/iam/`  ← hits this

The node's IAM role (`eks-nodegroup-role`) is returned, which typically only has permissions for EKS node operations — not DynamoDB.

---

### Q2 — Why is IRSA not working?

Check these 4 things in order:

#### Check 1 — ServiceAccount annotation missing

```bash
kubectl describe sa <serviceaccount-name> -n <namespace>
```

Expected output (working):
```yaml
Annotations:
  eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/payment-irsa-role
```

If this annotation is missing → IRSA never activates.

#### Check 2 — Pod not referencing the ServiceAccount

```bash
kubectl get pod <pod-name> -o yaml | grep serviceAccountName
```

Expected:
```yaml
spec:
  serviceAccountName: payment-service-sa
```

If `serviceAccountName` is missing or set to `default` → pod won't use IRSA.

#### Check 3 — IAM Trust Policy mismatch

The IAM role's trust policy must exactly match the cluster OIDC URL, namespace, and ServiceAccount name.

```json
{
  "Effect": "Allow",
  "Principal": {
    "Federated": "arn:aws:iam::123456789012:oidc-provider/oidc.eks.ap-south-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B716D3041E"
  },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": {
      "oidc.eks.ap-south-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B716D3041E:sub":
        "system:serviceaccount:default:payment-service-sa"
    }
  }
}
```

Common mistakes:
- Wrong namespace in `sub` field
- Wrong ServiceAccount name
- Wrong OIDC provider ID

#### Check 4 — OIDC Provider not set up on cluster

```bash
# Get cluster OIDC issuer
aws eks describe-cluster --name my-cluster \
  --query "cluster.identity.oidc.issuer" --output text

# Verify OIDC provider exists in IAM
aws iam list-open-id-connect-providers
```

If OIDC provider is missing → IRSA cannot work at all.

---

## Fix — Step by Step

### Step 1: Create IAM policy for DynamoDB

```json
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
```

```bash
aws iam create-policy \
  --policy-name payment-dynamodb-policy \
  --policy-document file://dynamodb-policy.json
```

### Step 2: Create IAM role with OIDC trust policy

```bash
aws iam create-role \
  --role-name payment-irsa-role \
  --assume-role-policy-document file://trust-policy.json
```

### Step 3: Attach policy to role

```bash
aws iam attach-role-policy \
  --role-name payment-irsa-role \
  --policy-arn arn:aws:iam::123456789012:policy/payment-dynamodb-policy
```

### Step 4: Create and annotate the ServiceAccount

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

# OR annotate existing SA
kubectl annotate serviceaccount payment-service-sa \
  eks.amazonaws.com/role-arn=arn:aws:iam::123456789012:role/payment-irsa-role
```

### Step 5: Update Deployment to use the ServiceAccount

```yaml
spec:
  template:
    spec:
      serviceAccountName: payment-service-sa
      containers:
        - name: payment-service
          image: payment-service:latest
```

### Step 6: Restart pods (mandatory — existing pods won't get new token)

```bash
kubectl rollout restart deployment payment-service
```

### Step 7: Verify IRSA token is injected

```bash
kubectl exec -it <pod-name> -- env | grep AWS
```

Expected output:
```
AWS_ROLE_ARN=arn:aws:iam::123456789012:role/payment-irsa-role
AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/serviceaccount/token
```

If both these env vars are present → IRSA is working correctly.

---

## How IRSA Works Internally

When IRSA is correctly set up, EKS automatically:

1. Mounts a **projected service account token** (JWT) into the pod at `/var/run/secrets/eks.amazonaws.com/serviceaccount/token`
2. Sets `AWS_WEB_IDENTITY_TOKEN_FILE` and `AWS_ROLE_ARN` env vars
3. AWS SDK reads these → calls `sts:AssumeRoleWithWebIdentity`
4. STS validates the JWT against the cluster OIDC provider
5. Returns temporary credentials scoped to the pod's IAM role

The pod **never** touches IMDS or the node role.

---

## Interview Answer (say this)

> "The pod was using the node IAM role because IRSA was not properly configured. When IRSA fails, the AWS SDK falls back to EC2 instance metadata and picks up the node's role, which doesn't have DynamoDB permissions. The fix involves four things: annotating the ServiceAccount with the IAM role ARN, ensuring the pod spec references that ServiceAccount, verifying the IAM trust policy has the correct OIDC provider URL and exact namespace/SA name, and restarting the pods so they receive fresh IRSA tokens. You can confirm it's working by checking for `AWS_ROLE_ARN` and `AWS_WEB_IDENTITY_TOKEN_FILE` inside the pod."

---

## Key Commands Cheatsheet

```bash
# Debug IRSA
kubectl describe sa <sa-name> -n <ns>
kubectl get pod <pod> -o yaml | grep serviceAccountName
kubectl exec -it <pod> -- env | grep AWS
aws iam get-role --role-name payment-irsa-role
aws iam list-attached-role-policies --role-name payment-irsa-role

# Verify OIDC
aws eks describe-cluster --name <cluster> --query "cluster.identity.oidc.issuer"
aws iam list-open-id-connect-providers

# Test DynamoDB access from pod
kubectl exec -it <pod> -- aws dynamodb get-item \
  --table-name customer-data \
  --key '{"id": {"S": "test"}}' \
  --region ap-south-1
```