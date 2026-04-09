#!/bin/bash
# ArgoCD Application 順次登録スクリプト
# Wave ごとに登録→Sync完了待ち→次の Wave へ進む
# 実行場所: Raspberry Pi
# 前提: install.sh 実行後、ArgoCD Pod が起動済みであること

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APPS_DIR="${SCRIPT_DIR}/apps"
ARGOCD_NS="argocd"

# ArgoCD Application が Synced かつ Healthy になるまで待つ
# $1: app名, $2: タイムアウト秒 (デフォルト300)
wait_app() {
  local app="$1"
  local timeout="${2:-300}"
  echo "  → ${app} の Sync/Healthy 待ち (最大 ${timeout}s)..."
  kubectl wait application "${app}" \
    -n "${ARGOCD_NS}" \
    --for=jsonpath='{.status.sync.status}'=Synced \
    --timeout="${timeout}s" 2>/dev/null || true
  kubectl wait application "${app}" \
    -n "${ARGOCD_NS}" \
    --for=jsonpath='{.status.health.status}'=Healthy \
    --timeout="${timeout}s" 2>/dev/null || true
}

echo "=== ArgoCD Server 起動待ち ==="
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=argocd-server \
  -n "${ARGOCD_NS}" \
  --timeout=120s

echo ""
echo "=== Wave 0: kyverno ==="
kubectl apply -f "${APPS_DIR}/kyverno.yaml"
wait_app kyverno 300
sleep 10

echo ""
echo "=== Wave 1: kyverno-policies ==="
wait_app kyverno-policies 180
sleep 10

echo ""
echo "=== Wave 3: monitoring ==="
kubectl apply -f "${APPS_DIR}/monitoring.yaml"
sleep 30

echo ""
echo "=== Wave 2 (オンデマンド): vault ==="
kubectl apply -f "${APPS_DIR}/vault.yaml"
sleep 10

echo ""
echo "=== Wave 4 (オンデマンド): harbor ==="
kubectl apply -f "${APPS_DIR}/harbor.yaml"
sleep 10

echo ""
echo "=== Wave 5 (オンデマンド): keycloak ==="
kubectl apply -f "${APPS_DIR}/keycloak.yaml"
sleep 10

echo ""
echo "=== Wave 6-8: logging ==="
kubectl apply -f "${APPS_DIR}/logging.yaml"
sleep 30

echo ""
echo "=== Wave 3 (オンデマンド): argo-workflows / argo-events ==="
kubectl apply -f "${APPS_DIR}/argo-workflows.yaml"
kubectl apply -f "${APPS_DIR}/argo-events.yaml"
sleep 10

echo ""
echo "=== Wave 9-10 (オンデマンド): tracing ==="
kubectl apply -f "${APPS_DIR}/tracing.yaml"
sleep 10

echo ""
echo "=== Wave 11-14: aiops ==="
kubectl apply -f "${APPS_DIR}/aiops.yaml"

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
