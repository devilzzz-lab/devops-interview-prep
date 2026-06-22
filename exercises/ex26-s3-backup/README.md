# Exercise 26: S3 Backup Solution

> Implement a backup strategy that backs up application files and config files to S3, with a demonstrated restore process.

---

## Folder structure

```
exercises/ex26-s3-backup/
├── app/
│   ├── app.py
│   └── config/
│       └── app.conf
├── scripts/
│   ├── backup.sh
│   └── restore.sh
└── README.md
```

---

## Step 1 — Create the folder structure

```bash
mkdir -p exercises/ex26-s3-backup/app/config
mkdir -p exercises/ex26-s3-backup/scripts

cd exercises/ex26-s3-backup
```

---

## Step 2 — Create dummy app and config files

### app/app.py

```python
# Dummy application file
print("Payment service running...")
```

### app/config/app.conf

```ini
[server]
host = 0.0.0.0
port = 8080

[database]
url = postgres://localhost:5432/payments
pool_size = 10

[logging]
level = INFO
output = /var/log/app.log
```

---

## Step 3 — Create an S3 bucket

```bash
aws s3 mb s3://my-app-backups-ex26 --region us-east-1
```

Verify it was created:

```bash
aws s3 ls | grep my-app-backups-ex26
```

Expected:

```text
2024-01-01 00:00:00 my-app-backups-ex26
```

---

## Step 4 — Write the backup script

### scripts/backup.sh

```bash
#!/bin/bash
set -euo pipefail

# ── Config ──────────────────────────────────────────────
BUCKET="s3://my-app-backups-ex26"
APP_DIR="./app"
TIMESTAMP=$(date +"%Y-%m-%dT%H-%M-%S")
BACKUP_PREFIX="backups/${TIMESTAMP}"

echo "==> Starting backup at ${TIMESTAMP}"

# ── Backup application files ─────────────────────────────
echo "--> Backing up application files..."
aws s3 sync "${APP_DIR}" "${BUCKET}/${BACKUP_PREFIX}/app/" \
  --exclude "*.pyc" \
  --exclude "__pycache__/*"

# ── Backup config files separately ───────────────────────
echo "--> Backing up config files..."
aws s3 sync "${APP_DIR}/config/" "${BUCKET}/${BACKUP_PREFIX}/config/"

# ── Tag the latest backup ────────────────────────────────
echo "--> Tagging latest backup pointer..."
echo "${BACKUP_PREFIX}" | aws s3 cp - "${BUCKET}/latest.txt"

echo "==> Backup complete: ${BUCKET}/${BACKUP_PREFIX}"
```

Make it executable:

```bash
chmod +x scripts/backup.sh
```

---

## Step 5 — Write the restore script

### scripts/restore.sh

```bash
#!/bin/bash
set -euo pipefail

# ── Config ──────────────────────────────────────────────
BUCKET="s3://my-app-backups-ex26"
RESTORE_DIR="./restored"

# ── Determine which backup to restore ───────────────────
if [ -z "${1:-}" ]; then
  echo "--> No timestamp provided, restoring latest backup..."
  BACKUP_PREFIX=$(aws s3 cp "${BUCKET}/latest.txt" -)
else
  BACKUP_PREFIX="backups/${1}"
  echo "--> Restoring specific backup: ${BACKUP_PREFIX}"
fi

echo "==> Restoring from: ${BUCKET}/${BACKUP_PREFIX}"

# ── Restore application files ────────────────────────────
echo "--> Restoring application files..."
mkdir -p "${RESTORE_DIR}/app"
aws s3 sync "${BUCKET}/${BACKUP_PREFIX}/app/" "${RESTORE_DIR}/app/"

# ── Restore config files ─────────────────────────────────
echo "--> Restoring config files..."
mkdir -p "${RESTORE_DIR}/config"
aws s3 sync "${BUCKET}/${BACKUP_PREFIX}/config/" "${RESTORE_DIR}/config/"

echo "==> Restore complete → ${RESTORE_DIR}/"
ls -lR "${RESTORE_DIR}"
```

Make it executable:

```bash
chmod +x scripts/restore.sh
```

---

## Step 6 — Run the backup

```bash
cd exercises/ex26-s3-backup
./scripts/backup.sh
```

Expected output:

```text
==> Starting backup at 2024-01-01T12-00-00
--> Backing up application files...
upload: app/app.py to s3://my-app-backups-ex26/backups/2024-01-01T12-00-00/app/app.py
upload: app/config/app.conf to s3://my-app-backups-ex26/backups/2024-01-01T12-00-00/app/config/app.conf
--> Backing up config files...
upload: app/config/app.conf to s3://my-app-backups-ex26/backups/2024-01-01T12-00-00/config/app.conf
--> Tagging latest backup pointer...
==> Backup complete: s3://my-app-backups-ex26/backups/2024-01-01T12-00-00
```

---

## Step 7 — Verify backup in S3

```bash
aws s3 ls s3://my-app-backups-ex26/backups/ --recursive
```

Expected:

```text
2024-01-01 12:00:00    123 backups/2024-01-01T12-00-00/app/app.py
2024-01-01 12:00:00    234 backups/2024-01-01T12-00-00/app/config/app.conf
2024-01-01 12:00:00    234 backups/2024-01-01T12-00-00/config/app.conf
```

Check the latest pointer:

```bash
aws s3 cp s3://my-app-backups-ex26/latest.txt -
```

Expected:

```text
backups/2024-01-01T12-00-00
```

---

## Step 8 — Demonstrate restore (latest)

```bash
# Restore the latest backup
./scripts/restore.sh
```

Expected output:

```text
--> No timestamp provided, restoring latest backup...
==> Restoring from: s3://my-app-backups-ex26/backups/2024-01-01T12-00-00
--> Restoring application files...
download: s3://my-app-backups-ex26/.../app/app.py to restored/app/app.py
download: s3://my-app-backups-ex26/.../app/config/app.conf to restored/app/config/app.conf
--> Restoring config files...
download: s3://my-app-backups-ex26/.../config/app.conf to restored/config/app.conf
==> Restore complete → restored/
restored/
restored/app
restored/app/app.py
restored/app/config
restored/app/config/app.conf
restored/config
restored/config/app.conf
```

---

## Step 9 — Demonstrate restore (specific timestamp)

```bash
# Restore a specific backup by timestamp
./scripts/restore.sh 2024-01-01T12-00-00
```

Expected output:

```text
--> Restoring specific backup: backups/2024-01-01T12-00-00
==> Restoring from: s3://my-app-backups-ex26/backups/2024-01-01T12-00-00
...
==> Restore complete → restored/
```

---

## Step 10 — Commit and push

```bash
git add exercises/ex26-s3-backup/
git commit -m "ex26: S3 backup and restore solution"
git push origin main
```

---

## Bonus — Enable S3 Versioning (extra safety)

```bash
aws s3api put-bucket-versioning \
  --bucket my-app-backups-ex26 \
  --versioning-configuration Status=Enabled
```

Verify:

```bash
aws s3api get-bucket-versioning --bucket my-app-backups-ex26
```

Expected:

```json
{
  "Status": "Enabled"
}
```

With versioning on, even if a backup is overwritten or deleted, S3 keeps all previous versions. Extra protection on top of timestamp-based backups.

---

## Key concepts to explain in interview

| Concept                      | What it does                                                             |
| ---------------------------- | ------------------------------------------------------------------------ |
| `aws s3 sync`                | Incrementally syncs only changed files — faster than full upload each time |
| `TIMESTAMP` in prefix        | Each backup is isolated under its own folder — no overwrites             |
| `latest.txt` pointer         | Stores the most recent backup path — restore script reads it automatically |
| `--exclude` flags            | Skips compiled/cache files like `.pyc` and `__pycache__`                 |
| `set -euo pipefail`          | Script fails fast on any error — no silent failures                      |
| S3 Versioning                | Adds another layer — S3 itself keeps object history even if files change |

---

## Interview answer (say this)

"I implemented an S3 backup solution with two shell scripts — backup.sh and restore.sh. The backup script uses aws s3 sync to upload application files and config files into timestamped prefixes in S3, so each backup is completely isolated. It also writes a latest.txt pointer so the restore script knows which backup to pull by default, without needing to specify a timestamp manually. The restore script supports two modes — restore latest, or restore a specific timestamp — which covers both day-to-day recovery and point-in-time recovery scenarios. I also enabled S3 versioning as an extra safety layer."