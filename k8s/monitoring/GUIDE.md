# Monitoring 詳細ガイド — Prometheus / Grafana / Alertmanager

## このスタックが解決する問題

クラスターやアプリが「今どういう状態か」を知る手段がなければ、障害が起きても原因を調べられない。
Monitoring スタックは以下を提供する:

- **何が起きているか** → Prometheus がメトリクスを収集
- **見える化** → Grafana がグラフ表示
- **異常の通知** → Alertmanager がアラートを送信

---

## Prometheus

### 概念

Prometheus は **Pull 型のメトリクス収集システム**。
監視対象のアプリやノードが HTTP エンドポイント (`/metrics`) でメトリクスを公開し、
Prometheus が定期的に取りに行く (スクレイプ) という仕組み。

```
監視対象 (/metrics を公開)
    ↑  Prometheus が定期的に取得 (Pull)
Prometheus (時系列 DB に保存)
    ↓
Grafana / Alertmanager が参照
```

**Push 型との違い:**
- Push 型: アプリが能動的にデータを送信する (例: InfluxDB + Telegraf)
- Pull 型: Prometheus が能動的に取得しに行く → アプリ側の設定が不要、Prometheus 側で一元管理できる

### メトリクスの種類

| 種類 | 説明 | 例 |
|------|------|----|
| Counter | 単調増加する値 | リクエスト数、エラー数 |
| Gauge | 増減する現在値 | CPU 使用率、メモリ使用量 |
| Histogram | 値の分布 | レスポンスタイムのパーセンタイル |
| Summary | Histogram に近いが計算方法が異なる | レイテンシの中央値 |

### ラベル

Prometheus のメトリクスはラベル (キー=値) で識別される。

```
http_requests_total{method="GET", status="200", pod="nginx-abc123"}
```

このラベルを使って「特定の Pod だけ」「特定のステータスだけ」を集計できる。

### PromQL (クエリ言語)

Grafana や Prometheus UI でメトリクスを検索・集計するための言語。

```promql
# 直近5分間の CPU 使用率 (全ノード)
100 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

# 直近5分間の HTTP リクエスト数 (1秒あたり)
rate(http_requests_total[5m])

# メモリ使用率 (%)
(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100
```

### このラボでの設定 (values.yaml)

```yaml
prometheus:
  prometheusSpec:
    retention: 7d      # 7日間データを保持
    resources:
      limits:
        memory: 512Mi  # メモリ上限
    storageSpec:
      volumeClaimTemplate:
        spec:
          resources:
            requests:
              storage: 10Gi  # 10GB のディスクを確保
```

---

## node_exporter

### 概念

**ノード (物理マシン / VM) のメトリクスを収集する Exporter**。
各 k3s ノードに DaemonSet として配置され、OS レベルの情報を `/metrics` として公開する。

収集するメトリクスの例:

| メトリクス | 内容 |
|-----------|------|
| `node_cpu_seconds_total` | CPU の使用時間 (mode: idle/user/system 等) |
| `node_memory_MemAvailable_bytes` | 利用可能なメモリ |
| `node_disk_read_bytes_total` | ディスク読み取りバイト数 |
| `node_network_transmit_bytes_total` | NIC 送信バイト数 |
| `node_filesystem_avail_bytes` | ファイルシステムの空き容量 |
| `node_load1` | 1分間のロードアベレージ |

---

## kube-state-metrics

### 概念

**Kubernetes オブジェクトの状態をメトリクスとして公開するコンポーネント**。
node_exporter が OS のメトリクスを収集するのに対し、kube-state-metrics は
Kubernetes のリソース (Pod, Deployment, Node など) の状態を収集する。

収集するメトリクスの例:

| メトリクス | 内容 |
|-----------|------|
| `kube_pod_status_phase` | Pod のフェーズ (Running/Pending/Failed 等) |
| `kube_deployment_status_replicas_available` | Deployment の利用可能 Pod 数 |
| `kube_node_status_condition` | ノードの状態 (Ready/NotReady 等) |
| `kube_pod_container_resource_limits` | コンテナのリソース上限 |
| `kube_persistentvolumeclaim_status_phase` | PVC の状態 |

---

## Grafana

### 概念

**データソースを接続してグラフ・ダッシュボードを作成する可視化ツール**。
Prometheus 以外にも Elasticsearch、Tempo、MySQL など多様なデータソースに接続できる。

### データソースの仕組み

```
Prometheus ──────────┐
Elasticsearch ───────┤──→ Grafana (一元的に可視化)
Tempo ───────────────┘
```

このラボでは以下が設定済み (`values.yaml` の `additionalDataSources`):
- **Prometheus** — デフォルト (自動設定)
- **Elasticsearch** — `fluent-bit-*` インデックスのログ
- **Tempo** — 分散トレース

### ダッシュボードの仕組み

ダッシュボードは JSON で定義され、Git で管理できる。
このラボでは `dashboards/` ディレクトリの ConfigMap を通じて Grafana に自動ロードされる。

```
ConfigMap (grafana_dashboard: "1" ラベル付き)
    ↓  Grafana の sidecar が検知
Grafana ダッシュボードとして自動登録
```

### Explore 機能

ダッシュボードを作らなくても、その場でクエリを実行してデータを確認できる機能。
ログ (Elasticsearch)、トレース (Tempo) もここから確認できる。

---

## Alertmanager

### 概念

**Prometheus が検知したアラートを受け取り、通知先にルーティングするコンポーネント**。
Prometheus 自体はアラートを発火するが、「誰に」「どうやって」通知するかは Alertmanager が担当する。

```
Prometheus (アラートルール評価)
    ↓ 条件を満たしたら Alert を発火
Alertmanager
    ↓ グループ化・重複排除・ルーティング
Slack / PagerDuty / メール etc.
```

### アラートルールの例

```yaml
# Prometheus のアラートルール (例)
- alert: HighMemoryUsage
  expr: (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100 > 90
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "メモリ使用率が 90% を超えています"
```

### このラボでの設定

現在は通知先が `null` (通知なし) に設定されている。
Slack 通知を有効にする場合は `values.yaml` の以下コメントを外す:

```yaml
alertmanager:
  config:
    receivers:
      - name: slack
        slack_configs:
          - api_url: "https://hooks.slack.com/services/YOUR/WEBHOOK/URL"
            channel: "#alerts"
```

---

## コンポーネント間の関係図

```
┌─────────────────────────────────────────┐
│  k3s クラスター                          │
│                                         │
│  node_exporter (各ノードに1つ)           │
│  kube-state-metrics                     │
│       ↑ スクレイプ                       │
│  Prometheus ────────────→ Alertmanager  │
│       ↓ クエリ                    ↓     │
│  Grafana                       Slack    │
└─────────────────────────────────────────┘
```

---

## よく使うコマンド

```bash
# 全 Pod の状態確認
kubectl get pods -n monitoring

# Prometheus の設定確認 (スクレイプ対象など)
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
# → http://localhost:9090/targets でスクレイプ対象の状態を確認できる

# Grafana のログ確認
kubectl logs -n monitoring -l app.kubernetes.io/name=grafana

# Alertmanager のアクティブなアラート確認
kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093
# → http://localhost:9093

# メトリクスの直接確認 (node_exporter)
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus-node-exporter 9100:9100
# → http://localhost:9100/metrics
```

---

## トラブルシューティング

### Grafana に Pod のメトリクスが表示されない

```bash
# kube-state-metrics が動いているか確認
kubectl get pods -n monitoring -l app.kubernetes.io/name=kube-state-metrics

# Prometheus のターゲット確認 (port-forward 後)
curl http://localhost:9090/api/v1/targets | python3 -m json.tool | grep health
```

### Prometheus がデータを保持できない

storage の PVC が不足している可能性がある。

```bash
kubectl get pvc -n monitoring
kubectl describe pvc -n monitoring prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0
```
