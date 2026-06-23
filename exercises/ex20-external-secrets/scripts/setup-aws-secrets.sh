#!/bin/bash
set -euo pipefail

REGION="us-east-1"
SECRET_NAME="ex20/app/secret"

echo "==> Creating secret in AWS Secrets Manager..."

aws secretsmanager create-secret \
  --name "${SECRET_NAME}" \
  --region "${REGION}" \
  --secret-string '{
    "DB_USERNAME": "admin",
    "DB_PASSWORD": "SuperSecurePass123!",
    "JWT_SECRET": "myjwtsecretkey-do-not-expose"
  }'

echo "==> Secret created!"
echo "--> Verifying..."

aws secretsmanager get-secret-value \
  --secret-id "${SECRET_NAME}" \
  --region "${REGION}" \
  --query 'SecretString' \
  --output text | jq .