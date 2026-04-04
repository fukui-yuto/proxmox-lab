#!/bin/bash
# Harbor デプロイスクリプト
# 実行場所: Raspberry Pi (ansible 実行環境)
# 前提: kubectl が k3s クラスターに接続できること

set -euo pipefail

NAMESPACE="harbor"
RELEASE_NAME="harbor"
CHART_VERSION="1.14.2"

echo "=== Helm リポジトリ追加 ==="
helm repo add harbor https://helm.goharbor.io
helm repo update

echo "=== Namespace 作成 ==="
kubectl apply -f namespace.yaml

echo "=== Harbor デプロイ ==="
helm upgrade --install "${RELEASE_NAME}" \
  harbor/harbor \
  --namespace "${NAMESPACE}" \
  --version "${CHART_VERSION}" \
  --values values-harbor.yaml \
  --timeout 15m \
  --wait

echo "=== デプロイ確認 ==="
kubectl get pods -n "${NAMESPACE}"

echo ""
echo "=== アクセス情報 ==="
echo "Harbor UI: http://harbor.homelab.local"
echo "  ユーザー: admin"
echo "  パスワード: Harbor12345  ← 必ず変更してください"
echo ""
echo "=== Docker login コマンド ==="
echo "  docker login harbor.homelab.local -u admin -p Harbor12345"
echo ""
echo "hosts ファイルへの追記が必要な場合:"
echo "  192.168.210.24  harbor.homelab.local"
echo ""
echo "=== k3s insecure registry 設定 ==="
echo "各 k3s ノードで以下を実行してください:"
echo "  sudo bash -c 'cat >> /etc/rancher/k3s/registries.yaml << EOF"
echo "mirrors:"
echo "  harbor.homelab.local:"
echo "    endpoint:"
echo "      - \"http://harbor.homelab.local\""
echo "EOF'"
echo "  sudo systemctl restart k3s  # master の場合"
echo "  sudo systemctl restart k3s-agent  # worker の場合"
