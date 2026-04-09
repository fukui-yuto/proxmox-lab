#!/bin/bash
# ArgoCD Application 一括登録スクリプト
# 実行場所: Raspberry Pi
# 前提: install.sh 実行後、ArgoCD Pod が起動済みであること

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPS_DIR="${SCRIPT_DIR}/apps"
ARGOCD_NS="argocd"

echo "=== ArgoCD Server 起動待ち ==="
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=argocd-server \
  -n "${ARGOCD_NS}" \
  --timeout=120s

echo ""
echo "=== 常時起動アプリを登録 (automated sync) ==="
kubectl apply -f "${APPS_DIR}/kyverno.yaml"
kubectl apply -f "${APPS_DIR}/monitoring.yaml"
kubectl apply -f "${APPS_DIR}/logging.yaml"
kubectl apply -f "${APPS_DIR}/aiops.yaml"

echo ""
echo "=== オンデマンドアプリを登録 (手動 sync) ==="
kubectl apply -f "${APPS_DIR}/vault.yaml"
kubectl apply -f "${APPS_DIR}/harbor.yaml"
kubectl apply -f "${APPS_DIR}/keycloak.yaml"
kubectl apply -f "${APPS_DIR}/tracing.yaml"
kubectl apply -f "${APPS_DIR}/argo-workflows.yaml"
kubectl apply -f "${APPS_DIR}/argo-events.yaml"

echo ""
echo "=== 登録済み Application 一覧 ==="
kubectl get applications -n "${ARGOCD_NS}"

echo ""
echo "=== 完了 ==="
echo "ArgoCD UI: http://argocd.homelab.local"
echo ""
echo "常時起動アプリ (Sync Wave 0→14 で自動デプロイ中):"
echo "  kyverno → kyverno-policies → monitoring → logging → aiops"
echo ""
echo "オンデマンドアプリは ArgoCD UI から手動 Sync してください:"
echo "  vault / harbor / keycloak / tracing / argo-workflows / argo-events"
