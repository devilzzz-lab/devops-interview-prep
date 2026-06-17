# Exercise 12 — Node NotReady — DiskPressure

## Incident

```
Node Status:   NotReady
DiskPressure:  True
Journal:       no space left on device
du -sh /var/log/containers/*  →  95GB consumed
```

## What happened

Container logs grew to 95GB and filled the node disk. Kubelet panicked, set `DiskPressure=True`, started evicting pods, and eventually marked the node `NotReady`.

## Cause and Effect

```
Container logs pile up (/var/log/containers/ → 95GB)
 ↓
Disk full (no space left on device)
 ↓
kubelet detects DiskPressure=True
 ↓
 ├── Pods evicted (best-effort pods first)
 └── Node tainted (node.kubernetes.io/disk-pressure)
 ↓
Node status: NotReady
```

> DiskPressure and Unhealthy are different things. Pods can be running fine but the node is still NotReady due to disk.

---

## Step 1 — Confirm the problem

```bash
kubectl get nodes
```

Expected output:

```
NAME           STATUS     ROLES    AGE
ip-10-0-1-45   NotReady   <none>   12d
```

```bash
kubectl describe node ip-10-0-1-45 | grep -A5 "Conditions"
```

Expected output:

```
Conditions:
  Type              Status
  MemoryPressure    False
  DiskPressure      True      ← this is your culprit
  PIDPressure       False
  Ready             False
```

```bash
# SSH into the node
ssh ec2-user@<node-ip>

# Check overall disk usage
df -h
```

Expected output:

```
Filesystem      Size  Used  Avail  Use%  Mounted on
/dev/xvda1       100G   97G    3G   97%  /
```

```bash
# Find the biggest log offenders
du -sh /var/log/containers/* | sort -rh | head -20
```

Expected output:

```
45G  /var/log/containers/payment-service-abc123_default_app-xyz.log
28G  /var/log/containers/order-service-def456_default_app-abc.log
12G  /var/log/containers/nginx-ingress-xyz_ingress_controller.log
```

---

## Step 2 — Free up disk safely (immediate fix)

> **Do NOT just `rm -rf`** — do it safely with `truncate`.

### Why truncate and not rm?

Because the container process still has the file open. Deleting it frees the filename but NOT the disk space until the process closes the file. `truncate -s 0` zeroes the file immediately and frees space right away.

### Step 2a — Truncate large container log files

```bash
sudo truncate -s 0 /var/log/containers/payment-service-abc123_default_app-xyz.log
sudo truncate -s 0 /var/log/containers/order-service-def456_default_app-abc.log

# Or truncate all logs over 1GB in one command
sudo find /var/log/containers -name "*.log" -size +1G -exec truncate -s 0 {} \;
sudo find /var/log/pods -name "*.log" -size +1G -exec truncate -s 0 {} \;
```

### Step 2b — Vacuum systemd journal logs

```bash
# Check how much journal is consuming
journalctl --disk-usage
```

Expected output:

```
Archived and active journals take up 2.3G in the filesystem.
```

```bash
# Keep only last 500MB of journal
sudo journalctl --vacuum-size=500M
```

Expected output:

```
Vacuuming done, freed 1.8G of archived journals from /run/systemd/journal.
```

### Step 2c — Verify disk is freed

```bash
df -h
```

Expected output after cleanup:

```
Filesystem      Size  Used  Avail  Use%  Mounted on
/dev/xvda1       100G   18G   82G   18%  /
```

---

## Step 3 — Restart kubelet to clear DiskPressure condition

Once disk is freed, kubelet re-evaluates automatically but restarting speeds it up:

```bash
sudo systemctl restart kubelet
```

Wait ~30 seconds, then verify:

```bash
kubectl get nodes
```

Expected output:

```
NAME           STATUS   ROLES    AGE
ip-10-0-1-45   Ready    <none>   12d
```

```bash
kubectl describe node ip-10-0-1-45 | grep -A5 "Conditions"
```

Expected output:

```
Conditions:
  Type              Status
  DiskPressure      False     ← cleared
  Ready             True      ← back online
```

---

## Step 4 — Reschedule evicted pods

Evicted pods stay in `Evicted` state permanently — they do NOT restart on their own.

```bash
# Find all evicted pods
kubectl get pods --all-namespaces | grep Evicted
```

Expected output:

```
NAMESPACE   NAME                          STATUS    AGE
default     payment-service-abc123        Evicted   14m
default     order-service-def456          Evicted   14m
```

```bash
# Delete all failed/evicted pods so deployments reschedule them
kubectl delete pods --all-namespaces --field-selector=status.phase=Failed
```

Expected output:

```
pod "payment-service-abc123" deleted
pod "order-service-def456" deleted
```

Verify new pods are running:

```bash
kubectl get pods -n default
```

Expected output:

```
NAME                           READY   STATUS    RESTARTS
payment-service-xyz789         1/1     Running   0
order-service-uvw123           1/1     Running   0
```

---

## Step 5 — Prevent recurrence (long-term fixes)

### Fix 1 — Set log rotation limits in containerd

Edit `/etc/docker/daemon.json` (or containerd equivalent):

```json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  }
}
```

This caps each container at `100MB × 3 files = 300MB max`. Restart containerd after:

```bash
sudo systemctl restart containerd
```

### Fix 2 — Configure kubelet eviction thresholds

In `/etc/kubernetes/kubelet-config.yaml`:

```yaml
evictionHard:
  nodefs.available: "10%"       # evict pods when disk < 10% free
  nodefs.inodesFree: "5%"
evictionSoft:
  nodefs.available: "15%"       # soft warn when disk < 15%
evictionSoftGracePeriod:
  nodefs.available: "1m30s"     # give pods 90s grace before eviction
```

This makes kubelet evict early instead of waiting until the disk is completely full.

### Fix 3 — Add Prometheus disk alert

```yaml
groups:
  - name: node-disk
    rules:
      - alert: NodeDiskWarning
        expr: |
          (node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) < 0.20
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Node {{ $labels.instance }} disk above 80%"

      - alert: NodeDiskCritical
        expr: |
          (node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) < 0.10
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Node {{ $labels.instance }} disk above 90% — DiskPressure imminent"
```

---

## Recovery summary — exact order

```
Step 1: kubectl describe node        → confirm DiskPressure=True
Step 2: ssh into node → df -h        → find which logs are big
Step 3: truncate -s 0 on large logs  → free disk immediately (not rm)
Step 4: journalctl --vacuum-size=500M → free journal space
Step 5: df -h                        → confirm disk freed
Step 6: systemctl restart kubelet    → clears DiskPressure condition
Step 7: kubectl get nodes            → confirm Ready
Step 8: kubectl delete pods --field-selector=status.phase=Failed
Step 9: kubectl get pods             → confirm pods rescheduled
```

---

## Key commands cheatsheet

```bash
# Diagnose
kubectl get nodes
kubectl describe node <node-name> | grep -A10 Conditions
ssh ec2-user@<node-ip>
df -h
du -sh /var/log/containers/* | sort -rh | head -20

# Fix disk
sudo find /var/log/containers -name "*.log" -size +1G -exec truncate -s 0 {} \;
sudo find /var/log/pods -name "*.log" -size +1G -exec truncate -s 0 {} \;
sudo journalctl --vacuum-size=500M

# Recover node
sudo systemctl restart kubelet
kubectl get nodes

# Recover pods
kubectl get pods --all-namespaces | grep Evicted
kubectl delete pods --all-namespaces --field-selector=status.phase=Failed
```

---

## Interview answer (say this)

> "The node went `NotReady` because container logs filled the disk to 95GB — kubelet set `DiskPressure=True`, started evicting best-effort pods, and marked the node `NotReady`. To recover safely, I SSH into the node and use `truncate -s 0` (not `rm`) on the large log files because the container process still has the file open — deleting it doesn't free disk space until the process closes it, but truncating zeroes it immediately. Then I vacuum the journal, restart kubelet so it re-evaluates the disk condition, and delete the evicted pods so deployments reschedule them. Long-term fix is setting log rotation limits in containerd config, configuring kubelet eviction thresholds to warn at 80% disk, and adding a Prometheus alert so we catch it before hitting DiskPressure."