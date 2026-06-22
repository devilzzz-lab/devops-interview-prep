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