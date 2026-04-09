#!/bin/bash
# Keycloak デプロイスクリプト
# 実行場所: Raspberry Pi (ansible 実行環境)
# 前提: kubectl が k3s クラスターに接続できること
# 注意: bitnami chart は 2025年8月以降イメージが有料化のため manifest 方式に変更

set -euo pipefail

NAMESPACE="keycloak"

echo "=== Namespace 作成 ==="
kubectl apply -f namespace.yaml

echo "=== Keycloak デプロイ (PostgreSQL + Keycloak) ==="
kubectl apply -f keycloak.yaml

echo "=== デプロイ確認 ==="
kubectl get pods -n "${NAMESPACE}"

echo ""
echo "=== アクセス情報 ==="
echo "Keycloak UI: http://keycloak.homelab.local"
echo "  ユーザー: admin"
echo "  パスワード: Keycloak12345  ← 必ず変更してください"
echo ""
echo "hosts ファイルへの追記が必要な場合:"
echo "  192.168.210.24  keycloak.homelab.local"
echo ""
echo "=== 次のステップ ==="
echo "初回デプロイ時は realm・クライアント・SSO 設定を行う:"
echo "  bash setup.sh"
