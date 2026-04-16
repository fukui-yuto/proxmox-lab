# KEDA

Kubernetes Event-Driven Autoscaling — Prometheus / Kafka / Redis 等のイベントで Pod をゼロからスケールさせるオートスケーラー。

## 構成

| 項目 | 値 |
|------|-----|
| Helm chart | kedacore/keda 2.16.0 |
| Namespace | keda |
| ArgoCD Sync Wave | 4 |

## ファイル構成

```
k8s/keda/
├── values.yaml      # Helm values
├── README.md        # 本ファイル
└── GUIDE.md         # 概念説明・使い方

k8s/argocd/apps/
└── keda.yaml        # ArgoCD Application
```

## セットアップ

### ArgoCD への登録

```bash
# Raspberry Pi 上で実行
kubectl apply -f k8s/argocd/apps/keda.yaml
```

## 使い方 (Prometheus トリガーの例)

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: my-app-scaler
  namespace: my-namespace
spec:
  scaleTargetRef:
    name: my-app
  minReplicaCount: 0
  maxReplicaCount: 5
  triggers:
    - type: prometheus
      metadata:
        serverAddress: http://kube-prometheus-stack-prometheus.monitoring:9090
        metricName: http_requests_total
        threshold: "100"
        query: sum(rate(http_requests_total{job="my-app"}[1m]))
```

## 確認

```bash
kubectl get scaledobject -A
kubectl describe scaledobject <name> -n <namespace>
```

## 詳細

スケーラー種別・aiops 連携例などは [GUIDE.md](./GUIDE.md) を参照。
