#!/bin/bash
# Keycloak デプロイスクリプト
# 実行場所: Raspberry Pi (ansible 実行環境)
# 前提: kubectl が k3s クラスターに接続できること

set -euo pipefail

NAMESPACE="keycloak"
RELEASE_NAME="keycloak"
CHART_VERSION="21.4.4"

echo "=== Helm リポジトリ追加 ==="
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

echo "=== Namespace 作成 ==="
kubectl apply -f namespace.yaml

echo "=== Keycloak デプロイ ==="
helm upgrade --install "${RELEASE_NAME}" \
  bitnami/keycloak \
  --namespace "${NAMESPACE}" \
  --version "${CHART_VERSION}" \
  --values values-keycloak.yaml \
  --timeout 15m \
  --wait

echo "=== デプロイ確認 ==="
kubectl get pods -n "${NAMESPACE}"

echo ""
echo "=== アクセス情報 ==="
echo "Keycloak UI: http://keycloak.homelab.local"
echo "  ユーザー: admin"
echo "  パスワード: Keycloak12345  ← 必ず変更してください"
echo ""
echo "hosts ファイルへの追記が必要な場合:"
echo "  192.168.211.21  keycloak.homelab.local"
