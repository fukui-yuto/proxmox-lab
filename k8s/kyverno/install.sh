#!/bin/bash
# Kyverno デプロイスクリプト
# 実行場所: Raspberry Pi
# 前提: kubectl が k3s クラスターに接続できること

set -euo pipefail

NAMESPACE="kyverno"
KYVERNO_VERSION="3.2.6"

echo "=== Helm リポジトリ追加 ==="
helm repo add kyverno https://kyverno.github.io/kyverno
helm repo update

echo "=== Kyverno デプロイ ==="
helm upgrade --install kyverno \
  kyverno/kyverno \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --version "${KYVERNO_VERSION}" \
  --values values-kyverno.yaml \
  --timeout 5m \
  --wait

echo "=== ポリシー適用 ==="
kubectl apply -f policies/

echo "=== デプロイ確認 ==="
kubectl get pods -n "${NAMESPACE}"
kubectl get clusterpolicy

echo ""
echo "=== ポリシー一覧 ==="
echo "  - require-resource-limits : resource limits の必須化 (audit)"
echo "  - disallow-latest-tag     : latest タグの禁止 (audit)"
echo "  - require-labels          : app ラベルの必須化 (audit)"
echo ""
echo "enforce モードに変更する場合は policies/ 内の validationFailureAction を"
echo "  audit → enforce に変更して kubectl apply -f policies/ を再実行してください"
