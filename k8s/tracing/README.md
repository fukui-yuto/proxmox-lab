# Tracing — OpenTelemetry + Grafana Tempo

k3s クラスター上に分散トレーシング基盤を構築する。

## 構成

```
アプリケーション (OTLP / Jaeger)
    ↓
OpenTelemetry Collector  ← トレースを受信・変換・転送
    ↓
Grafana Tempo            ← トレースを保存
    ↓
Grafana                  ← トレースを可視化 (Explore タブ)
```

## 受信プロトコル

| プロトコル | ポート | 用途 |
|---|---|---|
| OTLP gRPC | 4317 | OpenTelemetry (推奨) |
| OTLP HTTP | 4318 | OpenTelemetry (HTTP) |
| Jaeger gRPC | 14250 | Jaeger クライアント |
| Jaeger HTTP | 14268 | Jaeger クライアント (HTTP) |

---

## デプロイ手順

Raspberry Pi 上で実行する。

```bash
cd ~/proxmox-lab/k8s/tracing
bash install.sh
```

### 手動で実行する場合

```bash
# Helm リポジトリ追加
helm repo add grafana https://grafana.github.io/helm-charts
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update

# Namespace 作成
kubectl apply -f namespace.yaml

# Grafana Tempo デプロイ
helm upgrade --install tempo \
  grafana/tempo \
  --namespace tracing \
  --version 1.7.2 \
  --values values-tempo.yaml \
  --timeout 5m \
  --wait

# OpenTelemetry Collector デプロイ
helm upgrade --install otel-collector \
  open-telemetry/opentelemetry-collector \
  --namespace tracing \
  --version 0.97.1 \
  --values values-otel-collector.yaml \
  --timeout 5m \
  --wait
```

---

## Grafana データソースの有効化

`monitoring/values.yaml` の `additionalDataSources` に Tempo はすでに追加済み。
デプロイ後に Grafana を再デプロイして反映する。

```bash
cd ~/proxmox-lab/k8s/monitoring
helm upgrade kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values values.yaml
```

---

## 動作確認

```bash
# Pod 確認
kubectl get pods -n tracing

# 期待する出力
NAME                                  READY   STATUS    RESTARTS
tempo-0                               1/1     Running   0
otel-collector-xxxxx                  1/1     Running   0

# Tempo の疎通確認
kubectl exec -n tracing tempo-0 -- \
  wget -qO- http://localhost:3100/ready
```

---

## Grafana でのトレース確認

1. `http://grafana.homelab.local` を開く
2. 左メニュー → **Explore**
3. データソースを **Tempo** に切り替える
4. トレース ID を入力するか、Search タブでクエリを実行する

---

## アプリからトレースを送信する場合

OTel Collector のエンドポイントにトレースを送信する。

```
OTLP gRPC: otel-collector.tracing.svc.cluster.local:4317
OTLP HTTP: otel-collector.tracing.svc.cluster.local:4318
```

---

## アンインストール

```bash
helm uninstall otel-collector -n tracing
helm uninstall tempo -n tracing
kubectl delete namespace tracing
```
