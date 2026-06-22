#!/bin/bash
set -euo pipefail

echo "============================================"
echo " 1. kubectl get externalsecret"
echo "============================================"
kubectl get externalsecret -n default

echo ""
echo "============================================"
echo " 2. kubectl get secret"
echo "============================================"
kubectl get secret app-secret -n default

echo ""
echo "============================================"
echo " 3. ExternalSecret detailed status"
echo "============================================"
kubectl describe externalsecret app-external-secret -n default \
  | grep -A 10 "Status:"

echo ""
echo "============================================"
echo " 4. Decode and verify secret values"
echo "============================================"
echo -n "DB_USERNAME : "
kubectl get secret app-secret -n default \
  -o jsonpath='{.data.DB_USERNAME}' | base64 -d
echo ""

echo -n "DB_PASSWORD : "
kubectl get secret app-secret -n default \
  -o jsonpath='{.data.DB_PASSWORD}' | base64 -d
echo ""

echo -n "JWT_SECRET  : "
kubectl get secret app-secret -n default \
  -o jsonpath='{.data.JWT_SECRET}' | base64 -d
echo ""