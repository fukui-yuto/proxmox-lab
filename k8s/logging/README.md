# Logging — Elasticsearch + Fluent Bit + Kibana

k3s クラスター上にログ収集基盤を構築する。

## 構成

```
Fluent Bit (DaemonSet)  ← 各ノードのコンテナログを収集
    ↓
Elasticsearch           ← ログを保存・インデックス化
    ↓
Kibana                  ← ログ分析 UI (http://kibana.homelab.local)
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

# Kibana デプロイ (Helm chart はセキュリティ前提のため plain Deployment を使用)
kubectl apply -f kibana.yaml

# Kibana 認証 (oauth2-proxy + Traefik forwardAuth)
kubectl apply -f oauth2-proxy.yaml
kubectl apply -f kibana-auth-middleware.yaml

# Ingress 適用
kubectl apply -f elasticsearch-ingress.yaml
kubectl apply -f kibana-ingress.yaml
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
kibana-kibana-xxxxx              1/1     Running   0
fluent-bit-xxxxx (各ノード)      1/1     Running   0

# Elasticsearch クラスター状態確認
kubectl exec -n logging elasticsearch-master-0 -- \
  curl -s http://localhost:9200/_cluster/health

# インデックス確認 (ログが届いていれば fluent-bit-* が表示される)
kubectl exec -n logging elasticsearch-master-0 -- \
  curl -s http://localhost:9200/_cat/indices?v
```

> **注意1:** Elasticsearch 8.x はデフォルトで TLS が有効。`values-elasticsearch.yaml` で `createCert: false` および `xpack.security.http.ssl.enabled: false` を設定することで HTTP を使用する。設定変更後は PVC を削除してクリーンインストールが必要。

> **注意3:** シングルノード構成では `elasticsearch.yml` に `discovery.type: single-node` を必ず設定する。未設定の場合、Helm chart が `discovery.seed_hosts=[elasticsearch-master-headless]` を自動付与し、30秒ごとに WARN ログが出力される。Fluent Bit がこれを収集するため Kibana ML ジョブ (Log Anomaly Detection) が誤検知する原因となる。

> **注意2:** シングルノード構成では replica を配置できないため、クラスター状態が `yellow` になり readiness probe が失敗する。以下のコマンドで全インデックスの replica を 0 に設定する。

```bash
kubectl exec -n logging elasticsearch-master-0 -- \
  curl -s -X PUT http://localhost:9200/_settings -H 'Content-Type: application/json' -d '{"index":{"number_of_replicas":0}}'
```

---

## アクセス

### Windows PC の hosts ファイルへの追記

管理者権限の PowerShell で実行:

```powershell
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.24  elasticsearch.homelab.local"
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.24  kibana.homelab.local"
```

### URL 一覧

| サービス | URL | 内容 |
|---|---|---|
| Kibana | http://kibana.homelab.local | ログ分析 UI (Keycloak SSO 認証) |
| Elasticsearch | http://elasticsearch.homelab.local | クラスター情報 |
| Elasticsearch | http://elasticsearch.homelab.local/_cat/indices?v | インデックス一覧 |
| Elasticsearch | http://elasticsearch.homelab.local/_cluster/health | クラスター状態 |

> **注意:** Kibana は起動に 3〜5 分かかる。

### Kibana 認証 (Keycloak SSO)

Kibana OSS には認証機能がないため、oauth2-proxy + Traefik forwardAuth で保護する。

| 項目 | 値 |
|------|-----|
| 認証方式 | oauth2-proxy (Keycloak OIDC) |
| ログイン | kibana.homelab.local にアクセスすると自動的に Keycloak にリダイレクト |
| ユーザー | `admin` / `Keycloak12345` |

構成:
```
ブラウザ → Traefik → [forwardAuth: oauth2-proxy] → Kibana
                         ↕
                    Keycloak (OIDC)
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
helm uninstall kibana -n logging
helm uninstall fluent-bit -n logging
helm uninstall elasticsearch -n logging
kubectl delete pvc -n logging elasticsearch-master-elasticsearch-master-0
kubectl delete namespace logging
```
