# Exercise 4 — External Secrets Failure Diagnosis

## Objective

Diagnose why an application cannot retrieve its database password from AWS Secrets Manager through External Secrets Operator.

---

## Symptoms

### Application Pod Logs

```text
FATAL:
Database password not found
Environment Variable DB_PASSWORD missing
```

### External Secret Status

```bash
kubectl get externalsecret
```

Expected:

```text
NAME          READY
db-secret     False
```

### External Secret Events

```text
SecretSyncedError

AccessDeniedException:
User is not authorized to perform:
secretsmanager:GetSecretValue
```

---

## Architecture

```text
Application Pod
      ↓
Kubernetes Secret
      ↓
ExternalSecret
      ↓
External Secrets Controller
      ↓
AWS Secrets Manager
```

The application never talks directly to AWS.

The flow is:

```text
AWS Secret
    ↓
External Secrets Operator
    ↓
Kubernetes Secret
    ↓
Environment Variable
    ↓
Application Pod
```

---

## Step 1 — Verify Application Failure

Check application pods:

```bash
kubectl get pods
```

View logs:

```bash
kubectl logs <pod-name>
```

Expected:

```text
FATAL:
Database password not found
Environment Variable DB_PASSWORD missing
```

### What this tells us

```text
Application cannot find DB_PASSWORD
```

But we still don't know whether:

```text
AWS issue
Kubernetes issue
External Secret issue
```

Need deeper investigation.

---

## Step 2 — Check External Secret Health

List External Secrets:

```bash
kubectl get externalsecret
```

Expected:

```text
NAME         READY
db-secret    False
```

### Interpretation

```text
READY=False
```

means:

```text
External Secret failed to synchronize
```

The Kubernetes Secret was not created correctly.

---

## Step 3 — Inspect External Secret

Describe the resource:

```bash
kubectl describe externalsecret db-secret
```

Look at Events section.

Expected:

```text
Events:

SecretSyncedError

AccessDeniedException:
User is not authorized to perform:
secretsmanager:GetSecretValue
```

### What this means

External Secrets Controller tried:

```text
AWS Secrets Manager
       ↓
GetSecretValue
```

AWS rejected the request.

---

## Step 4 — Check Controller Logs

Find controller:

```bash
kubectl get pods -A | grep external-secrets
```

Example:

```text
external-secrets-system
external-secrets-controller-abc123
```

Check logs:

```bash
kubectl logs \
-n external-secrets-system \
external-secrets-controller-abc123
```

Expected:

```text
AccessDeniedException

User is not authorized to perform:
secretsmanager:GetSecretValue
```

This confirms the same error reported by the External Secret resource.

---

## Step 5 — Verify Kubernetes Secret

Check whether the Secret exists:

```bash
kubectl get secret
```

or

```bash
kubectl get secret db-secret
```

Possible result:

```text
Error from server (NotFound)
```

or

```text
Secret exists but contains no data
```

### Why?

Because External Secrets Operator could not retrieve the secret value from AWS.

---

## Step 6 — Determine Root Cause

### AWS Issue?

YES ✅

Evidence:

```text
AccessDeniedException

User is not authorized to perform:
secretsmanager:GetSecretValue
```

This indicates:

```text
IAM Permission Problem
```

Possible causes:

```text
Missing IAM policy
Incorrect IAM Role
Broken IRSA configuration
Wrong AWS credentials
```

Required permission:

```json
{
  "Effect": "Allow",
  "Action": "secretsmanager:GetSecretValue",
  "Resource": "*"
}
```

---

### Kubernetes Issue?

NO ❌

Evidence:

```text
ExternalSecret exists
Controller is running
CRDs are working
```

No Kubernetes errors appear.

---

### Secret Issue?

NO ❌

The secret itself may exist correctly.

The operator simply cannot access it.

Example:

```text
Secret exists in AWS
      ↓
Access denied
      ↓
Sync fails
```

Therefore the secret content is not the problem.

---

## Verification Commands Summary

```bash
kubectl get externalsecret

kubectl describe externalsecret db-secret

kubectl get pods -A | grep external-secrets

kubectl logs -n external-secrets-system \
external-secrets-controller-xxxxx

kubectl get secret

kubectl describe secret db-secret
```

---

## Troubleshooting Flow

```text
Application Failure
        ↓
Check Pod Logs
        ↓
Check External Secret
        ↓
READY=False ?
        ↓
Describe External Secret
        ↓
Check Events
        ↓
Check Controller Logs
        ↓
Identify Root Cause
```

---

## Common External Secret Errors

| Error                       | Root Cause                   |
| --------------------------- | ---------------------------- |
| AccessDeniedException       | IAM Permission Issue         |
| SecretNotFound              | Wrong Secret Name            |
| ResourceNotFoundException   | Secret Missing in AWS        |
| InvalidClientTokenId        | Invalid AWS Credentials      |
| ExpiredTokenException       | Expired AWS Token            |
| SecretSynced=True           | External Secret Healthy      |
| Secret Exists but App Fails | Application/Kubernetes Issue |

---

## Final Diagnosis

```text
AWS Issue: YES

Kubernetes Issue: NO

Secret Issue: NO

Root Cause:
IAM permissions missing for:

secretsmanager:GetSecretValue
```

---

## Interview Answer

> "I would start from the application logs and confirm the environment variable is missing. Then I'd check the External Secret status. Since READY=False, I'd describe the External Secret and inspect its events. The AccessDeniedException indicates the External Secrets Controller cannot call AWS Secrets Manager GetSecretValue. I would verify this in the controller logs. Since the controller is running and Kubernetes resources are healthy, the root cause is not Kubernetes. The issue is an AWS IAM permission problem preventing the secret from being synchronized into a Kubernetes Secret."
