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
3. **EC2 Instance Metadata Service (IMDS)** → `http://169.254.169.254/latest/meta-data/iam/` ← hits this

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

### Step 1: Create the DynamoDB IAM Policy

First save this as `dynamodb-policy.json`:

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

Now create the policy in AWS:

```bash
aws iam create-policy \
  --policy-name payment-dynamodb-policy \
  --policy-document file://dynamodb-policy.json
```

Expected output — **copy the `Arn` value, you need it in Step 4:**

```json
{
  "Policy": {
    "PolicyName": "payment-dynamodb-policy",
    "PolicyId": "ANPA1234567890EXAMPLE",
    "Arn": "arn:aws:iam::123456789012:policy/payment-dynamodb-policy",
    "Path": "/",
    "DefaultVersionId": "v1",
    "AttachmentCount": 0,
    "CreateDate": "2026-05-10T08:30:00Z"
  }
}
```

---

### Step 2: Get your OIDC Provider URL (needed for trust policy)

```bash
aws eks describe-cluster \
  --name my-cluster \
  --query "cluster.identity.oidc.issuer" \
  --output text
```

Expected output:

```
https://oidc.eks.ap-south-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B716D3041E
```

**Copy the ID part** → `EXAMPLED539D4633E53DE1B716D3041E` (you need this in Step 3)

---

### Step 3: Create the Trust Policy file and IAM Role

Save this as `trust-policy.json` — replace the OIDC ID and account ID with yours:

```json
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
```

> **What this says:** "Only allow pods running as ServiceAccount `payment-service-sa` in namespace `default` on this specific EKS cluster to assume this role."

Now create the IAM role using this trust policy:

```bash
aws iam create-role \
  --role-name payment-irsa-role \
  --assume-role-policy-document file://trust-policy.json
```

Expected output — **copy the `Arn` value, you need it in Step 5:**

```json
{
  "Role": {
    "RoleName": "payment-irsa-role",
    "RoleId": "AROA1234567890EXAMPLE",
    "Arn": "arn:aws:iam::123456789012:role/payment-irsa-role",
    "CreateDate": "2026-05-10T08:35:00Z",
    "AssumeRolePolicyDocument": { "..." : "..." }
  }
}
```

---

### Step 4: Attach the DynamoDB policy to the role

Use the policy ARN from Step 1 output:

```bash
aws iam attach-role-policy \
  --role-name payment-irsa-role \
  --policy-arn arn:aws:iam::123456789012:policy/payment-dynamodb-policy
```

No output = success. Verify it attached:

```bash
aws iam list-attached-role-policies --role-name payment-irsa-role
```

Expected output:

```json
{
  "AttachedPolicies": [
    {
      "PolicyName": "payment-dynamodb-policy",
      "PolicyArn": "arn:aws:iam::123456789012:policy/payment-dynamodb-policy"
    }
  ]
}
```

---

### Step 5: Create the ServiceAccount in Kubernetes

Use the **role ARN from Step 3** in the annotation.

Save as `serviceaccount.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: payment-service-sa
  namespace: default
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/payment-irsa-role
```

Apply it:

```bash
kubectl apply -f serviceaccount.yaml
```

Expected output:

```
serviceaccount/payment-service-sa created
```

Verify the annotation is there:

```bash
kubectl describe sa payment-service-sa -n default
```

Expected output:

```
Name:                payment-service-sa
Namespace:           default
Annotations:         eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/payment-irsa-role
```

---

### Step 6: Update your Deployment to use the ServiceAccount

```yaml
spec:
  template:
    spec:
      serviceAccountName: payment-service-sa   # ← add this line
      containers:
        - name: payment-service
          image: payment-service:latest
```

Apply:

```bash
kubectl apply -f deployment.yaml
```

---

### Step 7: Restart pods (mandatory)

Existing running pods won't automatically get the new IRSA token. You must restart:

```bash
kubectl rollout restart deployment payment-service
```

Expected output:

```
deployment.apps/payment-service restarted
```

Watch pods come up:

```bash
kubectl rollout status deployment payment-service
```

Expected output:

```
Waiting for deployment "payment-service" rollout to finish: 1 out of 3 new replicas have been updated...
deployment "payment-service" successfully rolled out
```

---

### Step 8: Verify IRSA is working inside the pod

```bash
kubectl exec -it <pod-name> -- env | grep AWS
```

Expected output — **both lines must be present:**

```
AWS_ROLE_ARN=arn:aws:iam::123456789012:role/payment-irsa-role
AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/eks.amazonaws.com/serviceaccount/token
```

If you see these two → IRSA is injected correctly. Test actual DynamoDB access:

```bash
kubectl exec -it <pod-name> -- \
  aws dynamodb get-item \
  --table-name customer-data \
  --key '{"id": {"S": "test"}}' \
  --region ap-south-1
```

---

### Summary — What you created and in what order

```
Step 1: dynamodb-policy.json  →  aws iam create-policy        →  Policy ARN
Step 2: (get OIDC ID from EKS cluster)
Step 3: trust-policy.json     →  aws iam create-role          →  Role ARN
Step 4:                       →  aws iam attach-role-policy
Step 5: serviceaccount.yaml   →  kubectl apply                →  SA with Role ARN annotation
Step 6: deployment.yaml       →  add serviceAccountName
Step 7:                       →  kubectl rollout restart
Step 8:                       →  verify AWS env vars in pod
```

---

## How IRSA Works Internally

When IRSA is correctly set up, EKS automatically:

1. Mounts a **projected service account token** (JWT) into the pod at `/var/run/secrets/eks.amazonaws.com/serviceaccount/token`
2. Sets `AWS_ROLE_ARN` and `AWS_WEB_IDENTITY_TOKEN_FILE` env vars
3. AWS SDK reads these → calls `sts:AssumeRoleWithWebIdentity`
4. STS validates the JWT against the cluster OIDC provider
5. Returns temporary credentials scoped to the pod's IAM role

The pod **never** touches IMDS or the node role.

---

## Interview Answer (say this)

> "The pod was using the node IAM role because IRSA was not properly configured. When IRSA fails, the AWS SDK falls back to EC2 instance metadata and picks up the node's role, which doesn't have DynamoDB permissions. The fix involves: creating a DynamoDB IAM policy, creating an IAM role with a trust policy that references the cluster's OIDC provider and the exact namespace and ServiceAccount name, attaching the policy to the role, annotating the Kubernetes ServiceAccount with the role ARN, updating the pod to use that ServiceAccount, and restarting the pods so they receive fresh IRSA tokens. You confirm it's working by checking for `AWS_ROLE_ARN` and `AWS_WEB_IDENTITY_TOKEN_FILE` inside the pod."

---

## Key Commands Cheatsheet

```bash
# Debug IRSA
kubectl describe sa <sa-name> -n <ns>
kubectl get pod <pod> -o yaml | grep serviceAccountName
kubectl exec -it <pod> -- env | grep AWS

# Verify IAM
aws iam get-role --role-name payment-irsa-role
aws iam list-attached-role-policies --role-name payment-irsa-role

# Verify OIDC
aws eks describe-cluster --name <cluster> --query "cluster.identity.oidc.issuer"
aws iam list-open-id-connect-providers

# Test DynamoDB access from pod
kubectl exec -it <pod-name> -- aws dynamodb get-item \
  --table-name customer-data \
  --key '{"id": {"S": "test"}}' \
  --region ap-south-1
```