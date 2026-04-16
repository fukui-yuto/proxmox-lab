# KEDA ガイド

## 概要

KEDA (Kubernetes Event-Driven Autoscaling) は、イベントソースに基づいて Pod をゼロからスケールアウト/インできる Kubernetes オートスケーラー。
標準の HPA は CPU/メモリのみ対応だが、KEDA は Prometheus メトリクス・Kafka・Redis など多様なスケールトリガーに対応する。

### HPA との違い

| 機能 | HPA | KEDA |
|------|-----|------|
| トリガー | CPU / メモリのみ | 60+ のスケーラー |
| ゼロスケール | 不可 (min=1) | 可能 (min=0) |
| 外部イベント | 不可 | Kafka / SQS / Redis 等 |
| Prometheus 連携 | カスタムメトリクス要 | ネイティブ対応 |

---

## 主要リソース

### ScaledObject

Deployment / StatefulSet に対するスケール設定。

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: my-app-scaler
spec:
  scaleTargetRef:
    name: my-app
  minReplicaCount: 0
  maxReplicaCount: 10
  cooldownPeriod: 60
  triggers:
    - type: prometheus
      metadata:
        serverAddress: http://kube-prometheus-stack-prometheus.monitoring:9090
        metricName: http_requests_total
        threshold: "100"
        query: sum(rate(http_requests_total{job="my-app"}[1m]))
```

### ScaledJob

Job に対するスケール設定 (バッチ処理向け)。

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledJob
metadata:
  name: my-job-scaler
spec:
  jobTargetRef:
    template:
      spec:
        containers:
          - name: worker
            image: my-worker:latest
  triggers:
    - type: redis
      metadata:
        address: redis:6379
        listName: job-queue
        listLength: "5"
```

---

## スケーラー一覧 (homelab で使えるもの)

| スケーラー | 用途 |
|-----------|------|
| `prometheus` | Prometheus メトリクスでスケール |
| `cpu` | CPU 使用率 (HPA 互換) |
| `memory` | メモリ使用率 (HPA 互換) |
| `kafka` | Kafka コンシューマーラグ |
| `redis` | Redis リストの長さ |
| `cron` | 時刻ベースのスケール |

---

## aiops との統合例

aiops-auto-remediation と組み合わせると、アラート発生時に自動でワーカー数を増やす構成が可能。

```yaml
# Alertmanager がメトリクスを Pushgateway に送信
# → KEDA が Prometheus 経由でスケール判定
triggers:
  - type: prometheus
    metadata:
      serverAddress: http://kube-prometheus-stack-prometheus.monitoring:9090
      query: |
        count(ALERTS{alertname="HighErrorRate", alertstate="firing"})
      threshold: "1"
```

---

## 確認コマンド

```bash
# ScaledObject 一覧
kubectl get scaledobject -A

# ScaledJob 一覧
kubectl get scaledjob -A

# スケール状態の詳細
kubectl describe scaledobject <name> -n <namespace>
```
