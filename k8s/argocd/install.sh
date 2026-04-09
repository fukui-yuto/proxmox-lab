#!/bin/bash
# ArgoCD デプロイスクリプト
# 実行場所: Raspberry Pi (ansible 実行環境)
# 前提: kubectl が k3s クラスターに接続できること

set -euo pipefail

NAMESPACE="argocd"
RELEASE_NAME="argocd"
CHART_VERSION="9.4.17"

echo "=== Helm リポジトリ追加 ==="
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

echo "=== Namespace 作成 ==="
kubectl apply -f namespace.yaml

echo "=== ArgoCD デプロイ ==="
helm upgrade --install "${RELEASE_NAME}" \
  argo/argo-cd \
  --namespace "${NAMESPACE}" \
  --version "${CHART_VERSION}" \
  --values values-argocd.yaml \
  --timeout 10m \
  --wait

echo "=== Ingress port patch (443 → 80) ==="
# chart が port 443 の ingress を生成するため HTTP (port 80) に patch する
kubectl patch ingress argocd-server -n "${NAMESPACE}" --type=json \
  -p='[{"op":"replace","path":"/spec/rules/0/http/paths/0/backend/service/port/number","value":80}]'

echo "=== デプロイ確認 ==="
kubectl get pods -n "${NAMESPACE}"

echo ""
echo "=== アクセス情報 ==="
echo "ArgoCD UI: http://argocd.homelab.local"
echo ""
echo "=== 初期パスワードの取得 ==="
echo "以下のコマンドで admin の初期パスワードを取得してください:"
echo ""
echo "  kubectl get secret argocd-initial-admin-secret \\"
echo "    -n ${NAMESPACE} \\"
echo "    -o jsonpath='{.data.password}' | base64 -d && echo"
echo ""
echo "  ユーザー: admin"
echo "  パスワード: 上記コマンドの出力結果"
echo ""
echo "hosts ファイルへの追記が必要な場合:"
echo "  192.168.210.24  argocd.homelab.local"
