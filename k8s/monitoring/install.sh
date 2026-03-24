#!/bin/bash
# Prometheus + Grafana デプロイスクリプト
# 実行場所: Raspberry Pi (ansible 実行環境)
# 前提: kubectl が k3s クラスターに接続できること

set -euo pipefail

NAMESPACE="monitoring"
RELEASE_NAME="kube-prometheus-stack"
CHART_VERSION="61.3.2"  # 2024年時点の安定版

echo "=== Helm リポジトリ追加 ==="
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

echo "=== Namespace 作成 ==="
kubectl apply -f namespace.yaml

echo "=== kube-prometheus-stack デプロイ ==="
helm upgrade --install "${RELEASE_NAME}" \
  prometheus-community/kube-prometheus-stack \
  --namespace "${NAMESPACE}" \
  --version "${CHART_VERSION}" \
  --values values.yaml \
  --timeout 10m \
  --wait

echo "=== ダッシュボード ConfigMap 適用 ==="
kubectl apply -f dashboards/

echo "=== デプロイ確認 ==="
kubectl get pods -n "${NAMESPACE}"

echo ""
echo "=== アクセス情報 ==="
echo "Grafana: http://grafana.homelab.local"
echo "  ユーザー: admin"
echo "  パスワード: changeme  ← 必ず変更してください"
echo ""
echo "hosts ファイルへの追記が必要な場合:"
echo "  192.168.211.21  grafana.homelab.local"
