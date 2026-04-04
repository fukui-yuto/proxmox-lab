#!/bin/bash
# Vault デプロイスクリプト
# 実行場所: Raspberry Pi (ansible 実行環境)
# 前提: kubectl が k3s クラスターに接続できること

set -euo pipefail

NAMESPACE="vault"
RELEASE_NAME="vault"
CHART_VERSION="0.28.0"

echo "=== Helm リポジトリ追加 ==="
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

echo "=== Namespace 作成 ==="
kubectl apply -f namespace.yaml

echo "=== Vault デプロイ ==="
helm upgrade --install "${RELEASE_NAME}" \
  hashicorp/vault \
  --namespace "${NAMESPACE}" \
  --version "${CHART_VERSION}" \
  --values values-vault.yaml \
  --timeout 10m \
  --wait

echo "=== デプロイ確認 ==="
kubectl get pods -n "${NAMESPACE}"

echo ""
echo "=================================================================="
echo "=== Vault 初期化手順 (初回デプロイ時のみ実施) ==="
echo "=================================================================="
echo ""
echo "STEP 1: Vault の初期化"
echo "  kubectl exec -n ${NAMESPACE} vault-0 -- vault operator init \\"
echo "    -key-shares=5 \\"
echo "    -key-threshold=3"
echo ""
echo "  → Unseal Key 1〜5 と Initial Root Token が表示されます。"
echo "  → 必ず安全な場所に保管してください (再表示不可)。"
echo ""
echo "STEP 2: Vault のアンシール (3つのキーが必要)"
echo "  kubectl exec -n ${NAMESPACE} vault-0 -- vault operator unseal <Unseal Key 1>"
echo "  kubectl exec -n ${NAMESPACE} vault-0 -- vault operator unseal <Unseal Key 2>"
echo "  kubectl exec -n ${NAMESPACE} vault-0 -- vault operator unseal <Unseal Key 3>"
echo ""
echo "STEP 3: ステータス確認"
echo "  kubectl exec -n ${NAMESPACE} vault-0 -- vault status"
echo ""
echo "=================================================================="
echo ""
echo "=== アクセス情報 ==="
echo "Vault UI: http://vault.homelab.local"
echo ""
echo "hosts ファイルへの追記が必要な場合:"
echo "  192.168.210.24  vault.homelab.local"
