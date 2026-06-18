# Exercise 7 — ALB Ingress Failure

## Objective

Diagnose why an application exposed through an AWS Application Load Balancer (ALB) Ingress is inaccessible.

---

## Symptoms

### User Error

```text
504 Gateway Timeout
```

### Ingress Annotation

```yaml
alb.ingress.kubernetes.io/target-type: ip
```

### Ingress Events

```text
Target registration failed
```

### AWS Load Balancer Controller Logs

```text
Unable to discover subnets
```

---

## Architecture

```text
User
  ↓
ALB (Application Load Balancer)
  ↓
AWS Load Balancer Controller
  ↓
Ingress
  ↓
Target Group
  ↓
Pod IPs
  ↓
Application Pods
```

Traffic flow:

```text
User Request
      ↓
ALB
      ↓
Target Group
      ↓
Pod IP
      ↓
Application Response
```

---

## Step 1 — Verify Ingress

Check Ingress resources:

```bash
kubectl get ingress -A
```

Example:

```text
NAMESPACE     NAME              CLASS   HOSTS
production    payment-ingress   alb     *
```

Describe the Ingress:

```bash
kubectl describe ingress payment-ingress -n production
```

Expected:

```yaml
Annotations:
  alb.ingress.kubernetes.io/target-type: ip
```

---

## Step 2 — Check Ingress Events

Describe the Ingress and inspect Events:

```bash
kubectl describe ingress payment-ingress -n production
```

Expected:

```text
Events:

Target registration failed
```

### What this means

The AWS Load Balancer Controller attempted:

```text
Ingress
    ↓
Create Target Group
    ↓
Register Pod Targets
```

but failed before registration completed.

---

## Step 3 — Verify Application Pods

Check Pods:

```bash
kubectl get pods -n production -o wide
```

Expected:

```text
NAME              READY   STATUS    IP
api-pod-1         1/1     Running   10.0.1.15
api-pod-2         1/1     Running   10.0.2.10
```

Verify application health:

```bash
kubectl port-forward pod/api-pod-1 8080:8080
```

Test locally:

```bash
curl http://localhost:8080
```

If successful:

```text
Application is healthy
```

This indicates the application is not the root cause.

---

## Step 4 — Check Services

Verify Service:

```bash
kubectl get svc -n production
```

Describe Service:

```bash
kubectl describe svc api-service -n production
```

Verify endpoints:

```bash
kubectl get endpoints api-service -n production
```

Expected:

```text
NAME          ENDPOINTS
api-service   10.0.1.15:8080,10.0.2.10:8080
```

This confirms Pods are attached to the Service correctly.

---

## Step 5 — Check AWS Load Balancer Controller

Locate controller:

```bash
kubectl get pods -n kube-system | grep aws-load-balancer-controller
```

Example:

```text
aws-load-balancer-controller-abc123
```

View logs:

```bash
kubectl logs \
-n kube-system \
deployment/aws-load-balancer-controller
```

or

```bash
kubectl logs \
-n kube-system \
aws-load-balancer-controller-abc123
```

Expected:

```text
Unable to discover subnets
```

---

## Step 6 — Understand the Error

The ALB Controller must discover AWS subnets before creating:

```text
ALB
  ↓
Listeners
  ↓
Target Groups
```

When subnet discovery fails:

```text
Ingress Created
       ↓
Controller Starts Reconciliation
       ↓
Subnet Discovery Fails
       ↓
ALB Creation Fails
       ↓
Targets Cannot Register
       ↓
504 Gateway Timeout
```

---

## Step 7 — Verify Subnet Tags

The AWS Load Balancer Controller discovers subnets using AWS tags.

For public ALBs:

```text
kubernetes.io/role/elb=1
```

For private ALBs:

```text
kubernetes.io/role/internal-elb=1
```

Cluster ownership tag:

```text
kubernetes.io/cluster/<cluster-name>=owned
```

or

```text
kubernetes.io/cluster/<cluster-name>=shared
```

Missing tags commonly cause:

```text
Unable to discover subnets
```

---

## Step 8 — Verify Controller IAM Permissions

The controller also requires permissions such as:

```text
ec2:DescribeSubnets

ec2:DescribeVpcs

ec2:DescribeAvailabilityZones

elasticloadbalancing:*
```

Check IAM role attached to the controller.

If permissions are missing:

```text
Controller cannot discover networking resources
```

---

## Root Cause Analysis

### Application Issue?

NO ❌

Evidence:

```text
Pods are Running
Service Endpoints Exist
Application Responds Locally
```

Application is healthy.

---

### Kubernetes Issue?

NO ❌

Evidence:

```text
Ingress Exists
Pods Running
Service Correct
Endpoints Available
```

Core Kubernetes resources are functioning correctly.

---

### ALB Controller Issue?

YES ✅

Evidence:

```text
Unable to discover subnets
```

The controller cannot identify suitable AWS subnets for ALB creation.

---

### AWS Networking Issue?

YES ✅

Evidence:

```text
Target registration failed

Unable to discover subnets
```

Possible causes:

```text
Missing subnet tags

Wrong subnet configuration

Missing IAM permissions

Incorrect VPC setup
```

---

## Verification Commands Summary

```bash
kubectl get ingress -A

kubectl describe ingress <ingress-name>

kubectl get pods -o wide

kubectl get svc

kubectl get endpoints

kubectl logs \
-n kube-system \
deployment/aws-load-balancer-controller

kubectl get pods -n kube-system | grep aws-load-balancer-controller
```

---

## Troubleshooting Flow

```text
Application Unreachable
          ↓
504 Gateway Timeout
          ↓
Check Ingress
          ↓
Check Events
          ↓
Target Registration Failed ?
          ↓
Check Controller Logs
          ↓
Unable to Discover Subnets ?
          ↓
Verify AWS Subnet Tags
          ↓
Verify IAM Permissions
          ↓
Identify Root Cause
```

---

## Common ALB Controller Errors

| Error                      | Root Cause                       |
| -------------------------- | -------------------------------- |
| Unable to discover subnets | Missing subnet tags              |
| Failed build model         | Invalid Ingress annotation       |
| AccessDenied               | IAM permission issue             |
| Target registration failed | Target group configuration issue |
| No suitable subnets found  | AWS networking/tagging issue     |
| Failed deploy model        | ALB provisioning failure         |
| 504 Gateway Timeout        | ALB cannot reach healthy targets |

---

## Final Diagnosis

```text
Application Issue: NO

Kubernetes Issue: NO

ALB Controller Issue: YES

AWS Networking Issue: YES

Root Cause:

AWS Load Balancer Controller
cannot discover suitable AWS subnets.

Because subnet discovery fails,
the ALB cannot be created correctly,
targets cannot register,
and users receive 504 Gateway Timeout.
```

---

## Interview Answer

> "I would start by checking the Ingress resource and its events. The target registration failure indicates the ALB controller cannot successfully register backend targets. Next I would inspect the AWS Load Balancer Controller logs. The error 'Unable to discover subnets' points to an AWS infrastructure problem rather than an application issue. I would verify subnet tagging, VPC configuration, and controller IAM permissions. Since the Pods, Services, and Endpoints are healthy, the root cause is an AWS Load Balancer Controller subnet discovery failure preventing proper ALB provisioning and target registration."
