# Monitoring — Prometheus + Grafana

k3s クラスター上に `kube-prometheus-stack` を使ってメトリクス監視基盤を構築する。

## 構成

```
Prometheus      ← メトリクス収集 (node_exporter / kube-state-metrics)
Alertmanager    ← アラート通知
Grafana         ← ダッシュボード可視化 (http://grafana.homelab.local)
```

## 前提条件

- k3s クラスターが稼働していること
- `kubectl` が k3s クラスターに接続できること
- `helm` v3 がインストールされていること

```bash
# kubectl 接続確認
kubectl get nodes

# helm バージョン確認
helm version
```

## デプロイ手順

Raspberry Pi 上で実行する。

```bash
cd ~/proxmox-lab/k8s/monitoring

bash install.sh
```

### 手動で実行する場合

```bash
# Helm リポジトリ追加
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Namespace 作成
kubectl apply -f namespace.yaml

# デプロイ
helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --version 61.3.2 \
  --values values.yaml \
  --timeout 10m \
  --wait
```

## アクセス

### Grafana

| 項目 | 値 |
|------|-----|
| URL | http://grafana.homelab.local |
| ユーザー | `admin` |
| 初期パスワード | `values.yaml` の `grafana.adminPassword` を参照 |

> **注意:** 初回ログイン後に必ずパスワードを変更すること。

PC の hosts ファイルに以下を追記するか、Pi-hole に DNS レコードを追加する。

```
192.168.211.21  grafana.homelab.local
```

### Prometheus (ポートフォワード)

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
# http://localhost:9090
```

### Alertmanager (ポートフォワード)

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093
# http://localhost:9093
```

## 動作確認

```bash
# Pod の状態確認
kubectl get pods -n monitoring

# 全 Pod が Running になっていれば OK
NAME                                                   READY   STATUS    RESTARTS
kube-prometheus-stack-grafana-xxx                      3/3     Running   0
kube-prometheus-stack-prometheus-0                     2/2     Running   0
kube-prometheus-stack-alertmanager-0                   2/2     Running   0
kube-prometheus-stack-operator-xxx                     1/1     Running   0
kube-prometheus-stack-kube-state-metrics-xxx           1/1     Running   0
kube-prometheus-stack-prometheus-node-exporter-xxx     1/1     Running   0  (各ノード)
```

## Alertmanager の通知設定

`values.yaml` の `alertmanager.config.receivers` に Slack の Webhook URL を設定する。

```yaml
receivers:
  - name: slack
    slack_configs:
      - api_url: "https://hooks.slack.com/services/YOUR/WEBHOOK/URL"
        channel: "#alerts"
        send_resolved: true
```

設定後に再デプロイ:

```bash
helm upgrade kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values values.yaml
```

## アンインストール

```bash
helm uninstall kube-prometheus-stack -n monitoring
kubectl delete namespace monitoring
```

## 次のステップ

Phase 2 で Elasticsearch + Fluent Bit を追加した後、`values.yaml` の以下のコメントを外すと Grafana でログも確認できる。

```yaml
grafana:
  additionalDataSources:
    - name: Elasticsearch
      type: elasticsearch
      url: http://elasticsearch.elasticsearch.svc.cluster.local:9200
      ...
```
