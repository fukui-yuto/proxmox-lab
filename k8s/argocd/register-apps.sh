#!/bin/bash
# ArgoCD Application 登録スクリプト (App of Apps パターン)
#
# root-app を一度だけ apply する。以降は git push するだけで
# k8s/argocd/apps/ 内の全 Application が自動作成・更新される。
#
# 実行場所: Raspberry Pi
# 前提: install.sh 実行後、ArgoCD Pod が起動済みであること

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARGOCD_NS="argocd"

echo "=== ArgoCD Server 起動待ち ==="
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=argocd-server \
  -n "${ARGOCD_NS}" \
  --timeout=120s

echo ""
echo "=== Root App (App of Apps) を登録 ==="
kubectl apply -f "${SCRIPT_DIR}/root-app.yaml"

echo ""
echo "=== Root App の Sync 待ち (全 Application が生成されるまで) ==="
kubectl wait application root \
  -n "${ARGOCD_NS}" \
  --for=jsonpath='{.status.sync.status}'=Synced \
  --timeout=120s 2>/dev/null || true

echo ""
echo "=== 登録済み Application 一覧 ==="
kubectl get applications -n "${ARGOCD_NS}"

echo ""
echo "=== 完了 ==="
echo "ArgoCD UI: http://argocd.homelab.local"
echo ""
echo "全アプリが Sync Wave 0→15 の順に自動デプロイされます:"
echo "  Wave 0:  kyverno"
echo "  Wave 1:  kyverno-policies"
echo "  Wave 2:  longhorn-prereqs / longhorn"
echo "  Wave 3:  vault"
echo "  Wave 4:  monitoring / argo-workflows / argo-events"
echo "  Wave 5:  harbor"
echo "  Wave 6:  keycloak"
echo "  Wave 7:  logging-elasticsearch"
echo "  Wave 8:  logging-fluent-bit"
echo "  Wave 9:  logging-kibana"
echo "  Wave 10: tracing-tempo"
echo "  Wave 11: tracing-otel-collector"
echo "  Wave 12: aiops-alerting / aiops-pushgateway / aiops-image-build"
echo "  Wave 13: aiops-alert-summarizer / aiops-anomaly-detection"
echo "  Wave 14: aiops-auto-remediation"
echo "  Wave 15: aiops-auto-remediation-events"
