# Logging — Elasticsearch + Fluent Bit

k3s クラスター上にログ収集基盤を構築する。

## 構成

```
Fluent Bit (DaemonSet)  ← 各ノードのコンテナログを収集
    ↓
Elasticsearch           ← ログを保存・インデックス化
    ↓
Grafana                 ← ログを可視化 (Explore タブ)
```

## 前提条件

- k3s クラスターが稼働していること
- `monitoring/` の Prometheus + Grafana がデプロイ済みであること
- `kubectl` / `helm` が使える状態であること

---

## デプロイ手順

Raspberry Pi 上で実行する。

```bash
cd ~/proxmox-lab/k8s/logging
bash install.sh
```

### 手動で実行する場合

```bash
# Helm リポジトリ追加
helm repo add elastic https://helm.elastic.co
helm repo add fluent https://fluent.github.io/helm-charts
helm repo update

# Namespace 作成
kubectl apply -f namespace.yaml

# Elasticsearch デプロイ
helm upgrade --install elasticsearch \
  elastic/elasticsearch \
  --namespace logging \
  --version 8.5.1 \
  --values values-elasticsearch.yaml \
  --timeout 10m \
  --wait

# Fluent Bit デプロイ
helm upgrade --install fluent-bit \
  fluent/fluent-bit \
  --namespace logging \
  --version 0.47.9 \
  --values values-fluent-bit.yaml \
  --timeout 5m \
  --wait
```

---

## Grafana データソースの有効化

`monitoring/values.yaml` の `additionalDataSources` はすでに有効化済み。
Elasticsearch デプロイ後に Grafana を再デプロイして反映する。

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
kubectl get pods -n logging

# 期待する出力
NAME                             READY   STATUS    RESTARTS
elasticsearch-master-0           1/1     Running   0
fluent-bit-xxxxx (各ノード)      1/1     Running   0

# Elasticsearch クラスター状態確認
kubectl exec -n logging elasticsearch-master-0 -- \
  curl -s http://localhost:9200/_cluster/health | jq .

# インデックス確認 (ログが届いていれば fluent-bit-* が表示される)
kubectl exec -n logging elasticsearch-master-0 -- \
  curl -s http://localhost:9200/_cat/indices?v
```

---

## Grafana でのログ確認

1. `http://grafana.homelab.local` を開く
2. 左メニュー → **Explore**
3. データソースを **Elasticsearch** に切り替える
4. Index: `fluent-bit-*` でクエリを実行する

---

## アンインストール

```bash
helm uninstall fluent-bit -n logging
helm uninstall elasticsearch -n logging
kubectl delete namespace logging
```
