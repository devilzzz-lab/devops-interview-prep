# Exercise 8 – EKS Pod Connection Timeout to DynamoDB (Network Troubleshooting)

A request from a pod to DynamoDB passes through 4 layers in order. Any one blocking it causes exactly this symptom — connection timeout, not connection refused. Let's check each one.

---

# Why "timeout" specifically matters

| Error | Meaning | Indicates |
|--------|---------|-----------|
| **Connection timeout** | Packet sent, no response at all | Network layer block (SG, Route Table, NACL, Network Policy) |
| **Connection refused** | Packet reached destination, rejected | App-level block (wrong port, service down) |

Your error is **Connection timed out** — that tells us immediately this is a network layer 1-4 issue, not an application problem. This rules out the application code entirely and points straight at infrastructure.

---

# Step 1 — Check Network Policies first (cheapest to check)

```bash
kubectl get networkpolicy --all-namespaces
```

Expected output — look for any policy in your app's namespace:

```text
NAMESPACE   NAME                  POD-SELECTOR
default     deny-all-egress       app=payment-service
```

```bash
kubectl describe networkpolicy deny-all-egress -n default
```

Expected output (this would be the problem):

```text
Spec:
  PodSelector:     app=payment-service
  Policy Types:    Egress
  Egress:          <none>
```

← blocks ALL outbound traffic

If `Egress: <none>` with no rules listed, all egress traffic is blocked by default — including to DynamoDB. This is a very common interview trap.

### Fix — add an explicit egress rule

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dynamodb-egress
  namespace: default
spec:
  podSelector:
    matchLabels:
      app: payment-service
  policyTypes:
    - Egress
  egress:
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
      ports:
        - protocol: TCP
          port: 443
```

```bash
kubectl apply -f allow-dynamodb-egress.yaml
```

---

# Step 2 — Check Security Groups (the node/ENI level)

```bash
# Get the node's security group
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=*eks-node*" \
  --query "Reservations[].Instances[].SecurityGroups[].GroupId" \
  --output text
```

```bash
# Check outbound rules on that security group
aws ec2 describe-security-groups \
  --group-ids sg-0123456789abcdef \
  --query "SecurityGroups[].IpPermissionsEgress"
```

Expected (working):

```json
[
  {
    "IpProtocol": "-1",
    "IpRanges": [{"CidrIp": "0.0.0.0/0"}]
  }
]
```

Expected (broken — too restrictive):

```json
[
  {
    "IpProtocol": "tcp",
    "FromPort": 80,
    "ToPort": 80,
    "IpRanges": [{"CidrIp": "10.0.0.0/16"}]
  }
]
```

If you only see port 80 allowed, or only internal CIDR ranges, that's blocking HTTPS (443) traffic to DynamoDB.

### Fix — add outbound rule for HTTPS

```bash
aws ec2 authorize-security-group-egress \
  --group-id sg-0123456789abcdef \
  --protocol tcp \
  --port 443 \
  --cidr 0.0.0.0/0
```

---

# Step 3 — Check Route Tables

```bash
# Get subnet ID the node is in
kubectl get nodes -o jsonpath='{.items[0].spec.providerID}'

# Check the route table for that subnet
aws ec2 describe-route-tables \
  --filters "Name=association.subnet-id,Values=subnet-0123456789abcdef" \
  --query "RouteTables[].Routes"
```

Expected (working, private subnet with NAT):

```json
[
  {"DestinationCidrBlock": "10.0.0.0/16", "GatewayId": "local"},
  {"DestinationCidrBlock": "0.0.0.0/0", "NatGatewayId": "nat-0123456789abcdef"}
]
```

Expected (broken — no path out):

```json
[
  {"DestinationCidrBlock": "10.0.0.0/16", "GatewayId": "local"}
]
```

If there's no `0.0.0.0/0` route pointing to a NAT Gateway or Internet Gateway, the subnet has no path to the internet at all — this alone would cause every external curl to time out, not just DynamoDB.

### Fix — add NAT Gateway route (if private subnet should have internet access)

```bash
aws ec2 create-route \
  --route-table-id rtb-0123456789abcdef \
  --destination-cidr-block 0.0.0.0/0 \
  --nat-gateway-id nat-0123456789abcdef
```

---

# Step 4 — Check VPC Endpoints (the AWS-recommended fix)

This is actually the best practice fix for DynamoDB specifically — instead of routing through a NAT Gateway to the public internet, AWS lets you create a Gateway VPC Endpoint so traffic to DynamoDB stays entirely inside the AWS network, never touching the internet.

```bash
# Check if a DynamoDB VPC endpoint already exists
aws ec2 describe-vpc-endpoints \
  --filters "Name=service-name,Values=com.amazonaws.ap-south-1.dynamodb"
```

Expected (if missing):

```json
{
  "VpcEndpoints": []
}
```

Empty result means there's no VPC endpoint — this is very likely your actual root cause if the subnet is private with no NAT Gateway.

### Fix — create the VPC endpoint

```bash
aws ec2 create-vpc-endpoint \
  --vpc-id vpc-0123456789abcdef \
  --service-name com.amazonaws.ap-south-1.dynamodb \
  --route-table-ids rtb-0123456789abcdef \
  --vpc-endpoint-type Gateway
```

Expected:

```json
{
  "VpcEndpoint": {
    "VpcEndpointId": "vpce-0123456789abcdef",
    "State": "available"
  }
}
```

This automatically adds a route to the route table for DynamoDB's IP ranges, no NAT Gateway needed, and it's free (Gateway endpoints don't have an hourly charge, unlike Interface endpoints).

---

# Step 5 — Verify the fix

```bash
kubectl exec -it <pod-name> -- curl -v https://dynamodb.ap-south-1.amazonaws.com
```

Expected:

```text
* Connected to dynamodb.ap-south-1.amazonaws.com (xx.xx.xx.xx) port 443
< HTTP/1.1 400 Bad Request
```

**Note:** A `400 Bad Request` here is actually success at the network level — it means you reached DynamoDB and it responded (rejecting the malformed request since `curl` isn't sending a proper signed AWS API call). The connection itself worked.

---

# Decision tree — which layer is actually broken

| Symptom | Most likely cause |
|----------|-------------------|
| All external curls timeout (not just DynamoDB) | Route table missing `0.0.0.0/0` route |
| Only DynamoDB-specific calls fail, other HTTPS works | Missing VPC endpoint, or Network Policy blocking specific IP ranges |
| `kubectl describe networkpolicy` shows `Egress: <none>` | Network Policy is blocking everything |
| Security group has no outbound 443 rule | Security Group misconfigured |

---

# Interview answer (say this)

> "A connection timeout, as opposed to connection refused, tells me this is a network layer problem, not an application problem — the packet never got a response at all. I'd check four layers in order from closest to the pod outward: first Network Policies, since a deny-all-egress policy with no explicit allow rule is a common cause and the cheapest to check. Then Security Groups on the node, to confirm outbound 443 is allowed. Then Route Tables, to confirm the subnet actually has a path out, either to a NAT Gateway or directly to AWS services. And finally VPC Endpoints — for DynamoDB specifically, the best practice is a Gateway VPC Endpoint, which keeps traffic inside the AWS network entirely instead of routing through a NAT Gateway to the public internet. If the route table is missing the 0.0.0.0/0 route entirely, every external call would fail, not just DynamoDB, which helps narrow down whether it's a route table issue or a more specific VPC endpoint and network policy issue."