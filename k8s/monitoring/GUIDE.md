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

---

## ファイル構成と各ファイルのコード解説

### ファイル一覧

| ファイル | 役割 |
|---------|------|
| `namespace.yaml` | monitoring 名前空間の定義 |
| `values.yaml` | kube-prometheus-stack Helm チャートのカスタム設定 (本体) |
| `install.sh` | Helm インストール用の補助スクリプト |
| `dashboards/homelab-overview-cm.yaml` | Grafana ダッシュボード「Homelab Overview」の ConfigMap |
| `dashboards/k3s-cluster-cm.yaml` | Grafana ダッシュボード「k3s Cluster」の ConfigMap |
| `dashboards/log-anomaly-cm.yaml` | Grafana ダッシュボード「Log Anomaly Detection」の ConfigMap |

---

### namespace.yaml の解説

```yaml
apiVersion: v1          # Kubernetes コア API
kind: Namespace         # 名前空間リソース
metadata:
  name: monitoring      # "monitoring" という名前空間を作成
```

Kubernetes では名前空間 (Namespace) でリソースをグループ分けする。
monitoring スタックの全リソース (Prometheus, Grafana, Alertmanager 等) はこの `monitoring` 名前空間に配置される。
ArgoCD が最初にこのファイルを適用し、名前空間が存在しない場合に自動作成する。

---

### values.yaml の全セクション解説

`values.yaml` は kube-prometheus-stack Helm チャートに渡すカスタム値ファイル。
Helm チャートにはデフォルト値があり、このファイルで上書きしたい部分だけを記述する。

#### Prometheus セクション

```yaml
prometheus:
  prometheusSpec:
    retention: 7d          # メトリクスデータの保持期間。7日分を保存する
                           # 古いデータは自動で削除される (ディスク節約)

    # --- affinity (スケジューリング制約) ---
    # Prometheus Pod をどのノードに配置するかを制御する
    affinity:
      nodeAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:  # 「必須条件」(満たさないノードには配置しない)
          nodeSelectorTerms:
            - matchExpressions:
                - key: node-role.kubernetes.io/control-plane  # control-plane ラベル
                  operator: DoesNotExist  # ← このラベルが「存在しない」ノードにだけ配置
    # 理由: k3s-master (control-plane) はメモリ 6GB で k3s server プロセスと共存すると
    #        Prometheus の WAL replay 等で OOM Kill される危険があるため、ワーカーに配置する

    # --- resources (CPU / メモリの要求値と上限) ---
    resources:
      requests:           # スケジューラがノード選択時に確保する最低限のリソース
        cpu: 500m         # 0.5 CPU コア
        memory: 512Mi     # 512 MiB
      limits:             # この値を超えるとスロットル (CPU) または OOM Kill (メモリ)
        cpu: 1000m        # 1 CPU コア
        memory: 2Gi       # 2 GiB — WAL replay 時の OOM kill 対策で余裕を持たせている

    # --- storageSpec (永続ストレージ) ---
    storageSpec:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]    # 1つの Pod からのみ読み書き可能
          storageClassName: longhorn         # Longhorn 分散ストレージを使用
          resources:
            requests:
              storage: 10Gi                  # 10 GiB のボリュームを確保
    # Prometheus はメトリクスを時系列データとしてディスクに書き込む。
    # Pod が再起動してもデータが消えないように PVC (永続ボリューム) を使う。
```

**ポイント:**
- `retention: 7d` はホームラボ向けの短めの設定。本番環境では 30d〜90d が一般的
- `affinity` で master ノードを避けることで、Prometheus の大きなメモリ消費が k3s server と衝突するのを防ぐ
- `storageClassName: longhorn` により、ノード障害時もデータレプリカで保護される

#### Grafana セクション

```yaml
grafana:
  assertNoLeakedSecrets: false  # Helm チャートのセキュリティチェックを無効化
                                 # client_secret を values.yaml に直書きしているため
                                 # (本番では External Secrets 等を使うべき)

  adminPassword: "changeme"     # Grafana の admin ユーザーの初期パスワード

  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 200m
      memory: 256Mi

  # --- persistence (Grafana のデータ永続化) ---
  persistence:
    enabled: true                # ダッシュボード設定や内部 DB を永続化
    size: 2Gi                    # 2 GiB のボリュームを確保
    storageClassName: longhorn   # Longhorn を使用

  # --- grafana.ini (Grafana の設定ファイル) ---
  # Grafana は grafana.ini という INI 形式の設定ファイルで動作する。
  # Helm values では YAML で記述し、チャートが INI に変換してくれる。
  grafana.ini:
    server:
      domain: grafana.homelab.local          # Grafana のドメイン名
      root_url: "http://grafana.homelab.local" # OAuth のコールバック URL 等で使われる

    # --- Keycloak SSO 連携 (Generic OAuth) ---
    auth.generic_oauth:
      enabled: true                          # OAuth ログインを有効化
      name: Keycloak                         # ログイン画面に表示される名前
      allow_sign_up: true                    # OAuth で初回ログイン時にユーザーを自動作成
      client_id: grafana                     # Keycloak に登録したクライアント ID
      client_secret: grafana-keycloak-secret-2026  # クライアントシークレット
      scopes: openid profile email groups    # Keycloak に要求する情報の範囲
      # auth_url: ブラウザがリダイレクトされる認証 URL (外部からアクセス可能なURL)
      auth_url: http://keycloak.homelab.local/realms/homelab/protocol/openid-connect/auth
      # token_url: Grafana がトークンを取得する URL (クラスタ内部 DNS を使用)
      token_url: http://keycloak.keycloak.svc.cluster.local/realms/homelab/protocol/openid-connect/token
      # api_url: ユーザー情報取得 URL (クラスタ内部 DNS を使用)
      api_url: http://keycloak.keycloak.svc.cluster.local/realms/homelab/protocol/openid-connect/userinfo
      # role_attribute_path: Keycloak のグループに応じて Grafana のロールを割り当て
      # homelab-admins グループ → Admin、それ以外 → Viewer
      role_attribute_path: contains(groups[*], 'homelab-admins') && 'Admin' || 'Viewer'
  # 補足: auth_url はブラウザ (外部) からのアクセスなので homelab.local ドメインを使用。
  #        token_url / api_url は Grafana Pod (クラスタ内部) からのアクセスなので
  #        Kubernetes の Service DNS (.svc.cluster.local) を使用する。

  # --- Ingress (外部アクセス用のルーティング) ---
  ingress:
    enabled: true                    # Ingress リソースを作成する
    ingressClassName: traefik        # k3s デフォルトの Traefik Ingress Controller を使用
    hosts:
      - grafana.homelab.local        # このホスト名でアクセスを受け付ける
    paths:
      - /                            # ルートパス以下の全リクエストを Grafana に転送

  # --- additionalDataSources (追加データソース) ---
  # Prometheus はデフォルトで接続済み。以下は追加のデータソース。
  additionalDataSources:
    # Elasticsearch: fluent-bit が収集したログを検索・表示する
    - name: Elasticsearch
      type: elasticsearch
      url: http://elasticsearch-master.logging.svc.cluster.local:9200  # クラスタ内部 DNS
      jsonData:
        index: "fluent-bit-*"        # fluent-bit が書き込むインデックスパターン
        timeField: "@timestamp"      # 時刻フィールド名
        logMessageField: log         # ログ本文のフィールド名
        logLevelField: level         # ログレベルのフィールド名
        esVersion: "8.0.0"           # Elasticsearch のバージョン
        maxConcurrentShardRequests: 5  # 同時シャードリクエスト数の上限

    # Tempo: 分散トレースのデータソース
    - name: Tempo
      type: tempo
      url: http://tempo.tracing.svc.cluster.local:3100  # Tempo のクラスタ内部 DNS
      jsonData:
        httpMethod: GET
        serviceMap:
          datasourceUid: prometheus   # Tempo の Service Map で Prometheus のメトリクスを参照
```

**ポイント:**
- Keycloak SSO により、全サービスでシングルサインオンが可能
- `auth_url` (ブラウザ用) と `token_url` (Pod 間通信用) で異なるホスト名を使い分ける
- `additionalDataSources` で Grafana から Elasticsearch のログと Tempo のトレースも一元的に閲覧できる

#### Alertmanager セクション

```yaml
alertmanager:
  alertmanagerSpec:
    resources:              # Alertmanager は軽量なので控えめな設定
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        cpu: 100m
        memory: 128Mi

  config:
    global:
      resolve_timeout: 5m  # アラートが resolved にならない場合、5分後に自動 resolve

    # --- route (ルーティングツリー) ---
    # アラートをどの receiver に送るかを決めるルール。上から順に評価される。
    route:
      group_by: ["namespace", "alertname", "severity"]  # 同じ組み合わせのアラートをグループ化
      group_wait: 30s       # 新しいグループのアラートを 30秒待ってからまとめて送信
      group_interval: 5m    # 同じグループに新しいアラートが追加されたら 5分後に再送信
      repeat_interval: 4h   # 同じアラートが継続している場合、4時間ごとに再通知
      receiver: "null"      # デフォルトの receiver (どのルートにもマッチしなければここ)

      routes:
        # Watchdog はクラスタが正常であることを示すアラート → 通知不要なので null へ
        - matchers:
            - alertname = "Watchdog"
          receiver: "null"

        # --- 自動修復ルート ---
        # remediation ラベル付きのアラートは Argo Events へ送信して自動修復を起動
        - matchers:
            - remediation = "oom"
          receiver: "argo-events-oom"
          continue: true     # ← continue: true = このルートにマッチしても次のルートも評価する
                             #   → alert-summarizer にも転送される (二重送信)

        - matchers:
            - remediation = "crashloop"
          receiver: "argo-events-crashloop"
          continue: true

        - matchers:
            - remediation = "longhorn-faulted"
          receiver: "argo-events-longhorn-faulted"
          continue: true

        # severity = critical / warning のアラートは alert-summarizer へ
        - matchers:
            - severity = "critical"
          receiver: "alert-summarizer"
          continue: false    # ← continue: false = マッチしたらここで停止

        - matchers:
            - severity = "warning"
          receiver: "alert-summarizer"
          continue: false

    # --- inhibit_rules (抑制ルール) ---
    # 特定のアラートが発火中のとき、関連する別のアラートを抑制する
    inhibit_rules:
      # ルール1: ノードがダウンしたら、そのノード上の Pod/コンテナ系アラートは抑制
      # → ノード障害の根本原因だけに集中できる (アラートの嵐を防ぐ)
      - source_matchers:
          - alertname = "NodeNotReady"       # トリガー: ノードが NotReady
        target_matchers:
          - alertname =~ "Pod.*|Container.*|Kube.*"  # 抑制対象: Pod/Container/Kube 系
        equal: ["node"]                      # 同じ node ラベルを持つもの同士だけ

      # ルール2: Critical が出ているなら、同じ対象の Warning は抑制
      # → 重要度の高いアラートだけが通知される
      - source_matchers:
          - severity = "critical"
        target_matchers:
          - severity = "warning"
        equal: ["alertname", "namespace", "instance"]

    # --- receivers (通知先) ---
    receivers:
      - name: "null"                         # 何もしない (破棄用)

      - name: "alert-summarizer"             # AI 要約サービスへ Webhook 送信
        webhook_configs:
          - url: "http://alert-summarizer.aiops.svc.cluster.local:8080/webhook"
            send_resolved: false             # 解消通知は送らない (発火時のみ)

      - name: "argo-events-oom"              # OOM 自動修復トリガー
        webhook_configs:
          - url: "http://alertmanager-eventsource-svc.argo-events.svc.cluster.local:12000/oomkilled"
            send_resolved: false

      - name: "argo-events-crashloop"        # CrashLoop 自動修復トリガー
        webhook_configs:
          - url: "http://alertmanager-eventsource-svc.argo-events.svc.cluster.local:12000/crashloop"
            send_resolved: false

      - name: "argo-events-longhorn-faulted" # Longhorn 障害自動修復トリガー
        webhook_configs:
          - url: "http://alertmanager-eventsource-svc.argo-events.svc.cluster.local:12000/longhorn-faulted"
            send_resolved: false
```

**ポイント:**
- `continue: true` が付いたルートは、マッチしても次のルートの評価を継続する。これにより Argo Events (自動修復) と alert-summarizer (AI 要約) の両方にアラートを送れる
- `inhibit_rules` はアラートの嵐 (alert storm) を防ぐ重要な機能。ノード障害時に大量の Pod アラートが飛ぶのを抑制する
- 全ての receiver が `webhook_configs` を使用しており、HTTP POST でアラート情報を JSON として送信する

#### node_exporter / kube-state-metrics セクション

```yaml
# node_exporter: 各ノードの OS レベルメトリクス (CPU, メモリ, ディスク等)
prometheus-node-exporter:
  resources:
    requests:
      cpu: 50m            # 軽量なので控えめ
      memory: 32Mi
    limits:
      cpu: 100m
      memory: 64Mi

# kube-state-metrics: Kubernetes オブジェクトの状態メトリクス (Pod, Deployment 等)
kube-state-metrics:
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      cpu: 100m
      memory: 128Mi
```

どちらも DaemonSet / Deployment として動作し、Prometheus のスクレイプ対象になる。
リソース制限を設定することで、ホームラボの限られたリソースを守っている。

#### 無効化されたコンポーネント

```yaml
kubeEtcd:
  enabled: false              # k3s は標準の etcd ではなく SQLite (または embedded etcd) を使用
                              # → kube-prometheus-stack の etcd 監視は対象が存在しないため無効化

kubeControllerManager:
  enabled: false              # k3s では controller-manager が独立プロセスではなく
                              # k3s バイナリに統合されており、メトリクスエンドポイントに
                              # 直接アクセスできないため無効化

kubeScheduler:
  enabled: false              # 同上。k3s バイナリに統合されておりアクセス不可

kubeProxy:
  enabled: false              # k3s は kube-proxy を使用しない
                              # (k3s は独自の iptables/nftables ルール or Cilium で処理)
```

**なぜ無効化するのか:** kube-prometheus-stack は標準的な Kubernetes クラスターを前提としている。
k3s はこれらのコンポーネントをバイナリに統合している (または使用しない) ため、
有効のままだとスクレイプ失敗のエラーが大量に出る。k3s 環境では必ず無効化する。

---

### dashboards/ ConfigMap の仕組み

Grafana ダッシュボードを Kubernetes の ConfigMap として Git 管理し、自動でロードさせる仕組み。

#### ConfigMap の構造

```yaml
apiVersion: v1
kind: ConfigMap                      # Kubernetes の ConfigMap リソース
metadata:
  name: homelab-overview-dashboard   # ConfigMap の名前 (一意であること)
  namespace: monitoring              # monitoring 名前空間に作成
  labels:
    grafana_dashboard: "1"           # ★ この label が重要!
data:
  homelab-overview.json: |           # キー名 = ダッシュボードの JSON ファイル名
    {                                # 値 = Grafana ダッシュボードの JSON 定義
      "title": "Homelab Overview",
      "uid": "homelab-overview",
      ...
    }
```

#### 自動ロードの仕組み

kube-prometheus-stack の Grafana には **sidecar コンテナ** が同梱されている。
この sidecar が `grafana_dashboard: "1"` ラベルを持つ ConfigMap を監視し、
見つけたら自動的に Grafana にダッシュボードとして登録する。

```
[ConfigMap 作成/更新]
        │
        ▼
  grafana_dashboard: "1" ラベルあり?
        │
    Yes ▼
  Grafana sidecar が検知
        │
        ▼
  data 内の JSON を読み取り
        │
        ▼
  Grafana にダッシュボードとして登録
```

**新しいダッシュボードの追加手順:**
1. Grafana UI でダッシュボードを作成
2. JSON をエクスポート (Share → Export → Save to file)
3. ConfigMap YAML を作成し、`grafana_dashboard: "1"` ラベルを付ける
4. `dashboards/` ディレクトリに配置して git push
5. ArgoCD が自動で apply → sidecar が検知 → ダッシュボードが登録される

#### 現在のダッシュボード一覧

| ConfigMap 名 | ダッシュボード名 | 用途 |
|-------------|-----------------|------|
| `homelab-overview-dashboard` | Homelab Overview | ノード数、Pod 数、CPU/メモリ使用率など全体俯瞰 |
| `k3s-cluster-dashboard` | k3s Cluster | k3s クラスターのノード Ready 状態、リソース詳細 |
| `log-anomaly-dashboard` | Log Anomaly Detection | ログ異常検知の可視化 (aiops 連携) |

---

### Alertmanager ルーティングの流れ図

以下は Alertmanager がアラートを受信してから通知先に到達するまでの流れを示す。

```
                    Prometheus がアラートを発火
                              │
                              ▼
                     ┌─────────────────┐
                     │  Alertmanager   │
                     │  アラート受信    │
                     └────────┬────────┘
                              │
                    ┌─────────▼──────────┐
                    │ group_by で分類     │
                    │ (namespace,         │
                    │  alertname,         │
                    │  severity)          │
                    └─────────┬──────────┘
                              │
                    ┌─────────▼──────────┐
                    │ inhibit_rules 評価  │
                    │                    │
                    │ NodeNotReady 発火中 │──→ Pod/Container 系アラートを破棄
                    │ Critical 発火中    │──→ 同対象の Warning を破棄
                    └─────────┬──────────┘
                              │ (抑制されなかったアラート)
                              │
              ┌───────────────▼───────────────┐
              │       routes を上から順に評価    │
              └───────────────┬───────────────┘
                              │
          ┌───────────────────┼───────────────────┐
          │                   │                   │
          ▼                   ▼                   ▼
  alertname=Watchdog?   remediation=         severity=
          │             oom/crashloop/       critical/warning?
          │             longhorn-faulted?          │
          ▼                   │                   ▼
     ┌─────────┐              │            ┌──────────────────┐
     │  "null"  │              │            │ alert-summarizer │
     │ (破棄)   │              │            │ (AI 要約)        │
     └─────────┘              │            └──────────────────┘
                              │
                   ┌──────────▼──────────┐
                   │ continue: true       │
                   │ → 2箇所に同時送信    │
                   └──┬──────────────┬───┘
                      │              │
                      ▼              ▼
          ┌───────────────┐  ┌──────────────────┐
          │ Argo Events   │  │ alert-summarizer │
          │ (自動修復)     │  │ (AI 要約)        │
          │               │  │                  │
          │ oom → restart  │  │ アラート内容を    │
          │ crashloop →   │  │ LLM で要約して   │
          │   再起動       │  │ 通知             │
          │ longhorn →    │  │                  │
          │   volume 修復  │  │                  │
          └───────────────┘  └──────────────────┘
```

**流れのまとめ:**
1. Prometheus がアラートルールの条件を満たすと Alertmanager にアラートを送信
2. Alertmanager は `group_by` で同種のアラートをまとめ、`group_wait` の時間待つ
3. `inhibit_rules` で不要なアラートを抑制 (ノード障害時の Pod アラート等)
4. `routes` を上から順に評価し、最初にマッチした receiver に送信
5. `continue: true` のルートはマッチ後も次のルートを評価し続ける (複数送信が可能)
6. 最終的にどのルートにもマッチしなければデフォルトの `"null"` receiver (破棄) へ
