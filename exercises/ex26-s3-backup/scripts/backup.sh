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