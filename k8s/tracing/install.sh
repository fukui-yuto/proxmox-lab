#!/bin/bash
# Grafana Tempo + OpenTelemetry Collector デプロイスクリプト
# 実行場所: Raspberry Pi
# 前提: kubectl が k3s クラスターに接続できること

set -euo pipefail

NAMESPACE="tracing"
TEMPO_VERSION="1.7.2"
OTEL_VERSION="0.97.1"

echo "=== Helm リポジトリ追加 ==="
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update

echo "=== Namespace 作成 ==="
kubectl apply -f namespace.yaml

echo "=== Grafana Tempo デプロイ ==="
helm upgrade --install tempo \
  grafana/tempo \
  --namespace "${NAMESPACE}" \
  --version "${TEMPO_VERSION}" \
  --values values-tempo.yaml \
  --timeout 5m \
  --wait

echo "=== OpenTelemetry Collector デプロイ ==="
helm upgrade --install otel-collector \
  open-telemetry/opentelemetry-collector \
  --namespace "${NAMESPACE}" \
  --version "${OTEL_VERSION}" \
  --values values-otel-collector.yaml \
  --timeout 5m \
  --wait

echo "=== デプロイ確認 ==="
kubectl get pods -n "${NAMESPACE}"

echo ""
echo "=== 次のステップ ==="
echo "Grafana に Tempo データソースを反映するには:"
echo "  cd ../monitoring"
echo "  helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \\"
echo "    --namespace monitoring --values values.yaml"
