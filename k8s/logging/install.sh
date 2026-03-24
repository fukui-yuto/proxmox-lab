#!/bin/bash
# Elasticsearch + Fluent Bit デプロイスクリプト
# 実行場所: Raspberry Pi (ansible 実行環境)
# 前提: kubectl が k3s クラスターに接続できること

set -euo pipefail

NAMESPACE="logging"
ES_VERSION="8.5.1"
FB_CHART_VERSION="0.47.9"

echo "=== Helm リポジトリ追加 ==="
helm repo add elastic https://helm.elastic.co
helm repo add fluent https://fluent.github.io/helm-charts
helm repo update

echo "=== Namespace 作成 ==="
kubectl apply -f namespace.yaml

echo "=== Elasticsearch デプロイ ==="
helm upgrade --install elasticsearch \
  elastic/elasticsearch \
  --namespace "${NAMESPACE}" \
  --version "${ES_VERSION}" \
  --values values-elasticsearch.yaml \
  --timeout 10m \
  --wait

echo "=== Elasticsearch 疎通確認 ==="
kubectl run es-check --rm -i --restart=Never \
  --image=curlimages/curl:latest \
  --namespace "${NAMESPACE}" \
  -- curl -s http://elasticsearch-master:9200/_cluster/health | grep -q '"status"'
echo "Elasticsearch OK"

echo "=== Fluent Bit デプロイ ==="
helm upgrade --install fluent-bit \
  fluent/fluent-bit \
  --namespace "${NAMESPACE}" \
  --version "${FB_CHART_VERSION}" \
  --values values-fluent-bit.yaml \
  --timeout 5m \
  --wait

echo "=== Kibana デプロイ ==="
kubectl apply -f kibana.yaml
kubectl apply -f elasticsearch-ingress.yaml
kubectl apply -f kibana-ingress.yaml

echo "=== デプロイ確認 ==="
kubectl get pods -n "${NAMESPACE}"

echo ""
echo "=== アクセス情報 ==="
echo "Elasticsearch: http://elasticsearch.homelab.local"
echo "Kibana:        http://kibana.homelab.local"
