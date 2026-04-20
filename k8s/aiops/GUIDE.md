# AIOps 詳細ガイド — 予測アラート / 異常検知 / 自動修復

## 今の状態をどこで確認するか

AIOps の各コンポーネントは複数の UI に状態を記録する。
「今何が起きているか」を把握するための観測ポイントをまとめる。

```
観測したいこと                   見る場所
─────────────────────────────────────────────────────────────
クラスター全体のリソース状態      Grafana ダッシュボード
ログ異常スコアの推移              Grafana > Log Anomaly Detection
アラートが発火しているか          Grafana > Alerting > Alert rules
アラートのサマリ・経緯            Grafana > Annotations (時系列上の旗マーク)
ログの中身・エラー検索            Kibana
自動修復が実行されたか            Argo Workflows UI
AIOps コンポーネントの稼働状態    ArgoCD
```

### Grafana (`http://grafana.homelab.local`)

AIOps の主要な観測窓口。

| 場所 | 確認できること |
|------|--------------|
| **Dashboards > Log Anomaly Detection** | 異常スコアの推移・エラーレートの変化 |
| **Dashboards > Node Exporter Full** | ノードの CPU / メモリ / ディスク状態 |
| **Dashboards > Kubernetes / Compute Resources** | Pod・コンテナのリソース使用量 |
| **Alerting > Alert rules** | 現在発火中のアラート一覧と severity |
| **Explore > (データソース: Prometheus)** | PromQL で任意のメトリクスを調査 |
| **ダッシュボードの旗マーク (Annotations)** | alert-summarizer / 自動修復が記録したイベント |

Annotations は時系列グラフの上に重ねて表示されるため、
「CPU が上がったタイミングで何のアラートが来たか」を一目で確認できる。

```
Grafana ダッシュボード (時系列グラフ)
CPU使用率
100% │         ╱╲
 80% │        ╱  ╲
 60% │───────╱    ╲────
     │
     │    ↑ 🚨  ← Annotation (alert-summarizer が記録)
     └───────────────────────────→ 時間
```

### Kibana (`http://kibana.homelab.local`)

ログの中身を直接確認したいときに使う。

| 操作 | 確認できること |
|------|--------------|
| Discover > `fluent-bit-*` インデックス | 全 Pod のリアルタイムログ |
| フィルタ: `kubernetes.namespace_name: aiops` | AIOps 系コンポーネントのログのみ |
| フィルタ: `log.level: error` | エラーログのみ絞り込み |

異常検知 CronJob が「何を異常と判断したか」を確認する場合は
Kibana でエラーログのスパイクを目視確認すると分かりやすい。

### Argo Workflows (`http://argo-workflows.homelab.local`)

自動修復の実行履歴を確認する場所。

| 確認項目 | 場所 |
|---------|------|
| 過去のワークフロー実行一覧 | Workflows タブ |
| 各ステップの実行ログ | ワークフロー詳細 > ステップをクリック |
| 成功 / 失敗 / 実行中のステータス | ワークフロー一覧のステータスバッジ |

OOMKilled や CrashLoopBackOff が発生したとき、ここで
「いつ・どの Pod に対して・何をしたか」の履歴が確認できる。

### ArgoCD (`http://argocd.homelab.local`)

AIOps コンポーネント自体が正しくデプロイされているかを確認する場所。

| ArgoCD App | 確認対象 |
|-----------|---------|
| `aiops-alerting` | PrometheusRule (予測・自動修復アラート) |
| `aiops-pushgateway` | Prometheus Pushgateway |
| `aiops-anomaly-detection` | 異常検知 CronJob |
| `aiops-alert-summarizer` | alert-summarizer Deployment |
| `aiops-auto-remediation` | RBAC + WorkflowTemplates |
| `aiops-auto-remediation-events` | EventBus / EventSource / Sensor |

### kubectl による素早い状態確認

```bash
# 異常検知 CronJob の最終実行状況
kubectl get cronjob -n aiops

# 自動修復ワークフローの実行履歴
kubectl get workflows -n aiops

# alert-summarizer のログ (アラート受信履歴)
kubectl logs -n aiops deploy/alert-summarizer --tail=50

# Argo Events Sensor の状態
kubectl get sensor -n argo-events

# 現在発火中のアラートを Prometheus API で確認
kubectl exec -n monitoring prometheus-monitoring-kube-prometheus-prometheus-0 -- \
  wget -qO- 'localhost:9090/api/v1/alerts' | python3 -m json.tool | grep alertname
```

---

## このスタックが解決する問題

従来の監視は「閾値を超えたら通知する」という**リアクティブ**な設計が中心。
AIOps はそれを一歩進め、**障害が起きる前に予測し、起きたら自動で対処する**。

```
従来の監視 (リアクティブ)
  CPU 95% 超 → アラート → 人が気づく → 調査 → 対処
                ↑ すでに障害中

AIOps (プロアクティブ + 自動修復)
  CPU 上昇トレンドを検知 → 事前に警告
  ログ異常パターン検知  → 異常の予兆を可視化
  OOMKilled 発生        → 自動でメモリ増加
  CrashLoopBackOff      → ログ収集・エラー分類
```

---

## Step 1: 予測型・トレンド型アラート

### 閾値アラートの限界

```
ディスク残量
100GB ─────────────────────────────
 50GB ─────────────────── ← 閾値 (50%)
  0GB ──────────────────────────────────→ 時間
                         ↑ ここで通知
                         でも翌日には 0 になる
```

閾値アラートは「今の状態」しか見ていない。
`predict_linear()` を使えば「このままいくと N 時間後に枯渇する」と予測できる。

### predict_linear()

過去のデータの傾向 (回帰直線) から未来の値を予測する PromQL 関数。

```promql
# 過去 4 時間のトレンドで 24 時間後のディスク残量を予測
# 結果が 0 未満 = 24 時間以内に枯渇
predict_linear(
  node_filesystem_avail_bytes[4h],
  86400   # 予測する秒数 (86400 = 24 時間)
) < 0
```

**仕組み:**
```
現在値   過去データ (4h)
│        ●●●●●●●●●●● ← Prometheus が収集したメトリクス
│      ╱
│    ╱  ← この傾きから直線回帰
│  ╱
│╱_____________________________ 24時間後
↓
predict_linear() がこの予測値を返す
```

**サンプリング窓の選び方:**
- 短すぎる `[1h]` → 一時的なスパイクに反応しやすい
- 長すぎる `[24h]` → 直近の変化を捉えにくい
- ディスク: `[4h]` 程度が安定して機能する

### rate() と increase()

**rate():** カウンター値の「1秒あたりの増加速度」を返す

```promql
# 直近 5 分間の CPU アイドル率の変化速度 → CPU 使用率に変換
1 - avg by(instance)(rate(node_cpu_seconds_total{mode="idle"}[5m]))
```

**increase():** 指定期間内の「増加量の合計」を返す

```promql
# 直近 1 時間での Pod 再起動回数
increase(kube_pod_container_status_restarts_total[1h])
```

**rate vs increase の使い分け:**

| 用途 | 関数 | 理由 |
|------|------|------|
| 継続的な速度を見たい (CPU, ネットワーク) | `rate()` | 1秒あたりに正規化される |
| 期間内の累積量を見たい (再起動回数) | `increase()` | 増加量の合計が得られる |

### AlertManager: inhibit_rules (ノイズ抑制)

障害発生時に複数のアラートが同時に発火してノイズになる問題を解決する。

```
例: ノードがダウンした場合
  NodeNotReady (critical) → 発火
  PodNotRunning × 20      → 発火  ← ノードダウンの副作用なので不要
  KubeletNotReady         → 発火  ← 同上
```

`inhibit_rules` は「source_matchers が発火中は target_matchers を抑制する」というルール。

```yaml
inhibit_rules:
  - source_matchers:
      - alertname = "NodeNotReady"      # 原因アラート
    target_matchers:
      - alertname =~ "Pod.*|Kube.*"     # 抑制されるアラート
    equal: ["node"]                     # 同じノードのものだけ抑制
```

---

## Step 2: ログ異常検知 (ADTK)

### 異常検知とは

単純な閾値では「いつもより多い」を検知できない。
異常検知アルゴリズムは**過去の正常パターン**から「今の状態が異常かどうか」を判断する。

```
通常: ログ 100件/5分
ある日: ログ 1000件/5分 → 10倍に急増! → 何かが起きている?

閾値アラート: 「500件を超えたら通知」← 閾値の設定が難しい
異常検知:    「過去パターンから見て外れ値」← データ駆動で自動判断
```

### ADTK (Anomaly Detection Toolkit)

Python の時系列異常検知ライブラリ。実装済みアルゴリズム:

**InterQuartileRangeAD (IQR 法)**

過去データの四分位範囲 (Q1〜Q3) から外れた値を異常とみなす。
統計的に「外れ値」の定義として広く使われる手法。

```
Q1 (25パーセンタイル)   Q3 (75パーセンタイル)
     │                        │
─────┼────────────────────────┼───────
     │← IQR (四分位範囲) →│
                                        ●  ← 外れ値 (Q3 + 1.5×IQR 超)
```

**LevelShiftAD (レベルシフト検知)**

短期平均と長期平均を比較し、急激なレベル変化を検知する。
ゆっくり増加するトレンドではなく「突然の急増/急減」を捉えるのに適している。

```
エラーログ数
  │          ●●●●●●●●●  ← 急増 (LevelShift)
  │  ●●●●●●●
  └────────────────────→ 時間
         ↑ここで変化点を検知
```

### Prometheus Pushgateway パターン

Prometheus は Pull 型のため、Job や CronJob のような短命プロセスのメトリクスを直接収集できない。
Pushgateway はこの問題を解決するコンポーネント。

```
通常の Pull 型:
  Prometheus → (スクレイプ) → 常駐 Pod の /metrics

短命プロセスの Push 型:
  CronJob ─→ Pushgateway (メトリクスを保持)
                   ↑
              Prometheus がスクレイプ
```

**このラボでの使用:**

```
log-anomaly-detector CronJob
  (5分ごとに実行)
        ↓ prometheus_client で Push
  Prometheus Pushgateway
        ↓ Prometheus がスクレイプ
  Grafana でダッシュボード表示
```

---

## Step 3: アラート通知 (alert-summarizer)

### AlertManager Webhook

AlertManager はアラート発火時に設定した URL へ HTTP POST を送る仕組みを持つ。
これを使うことで独自のアラート処理を実装できる。

```yaml
receivers:
  - name: "alert-summarizer"
    webhook_configs:
      - url: "http://alert-summarizer.aiops.svc.cluster.local:8080/webhook"
```

**送信されるペイロード (抜粋):**

```json
{
  "status": "firing",
  "alerts": [
    {
      "status": "firing",
      "labels": {
        "alertname": "DiskSpaceExhaustionIn24h",
        "severity": "warning",
        "instance": "192.168.210.21:9100"
      },
      "annotations": {
        "summary": "ディスク空き容量が24時間以内に枯渇予測",
        "description": "..."
      },
      "startsAt": "2024-01-01T00:00:00Z"
    }
  ]
}
```

### FastAPI による Webhook サーバー

```
AlertManager
    ↓ POST /webhook
[FastAPI Pod]
    ├─ BackgroundTasks で非同期処理 ← 即座に 200 OK を返す
    │   ├─ Elasticsearch からログ取得
    │   └─ Grafana Annotation API に記録
    └─ GET /health (Liveness/Readiness Probe 用)
```

**BackgroundTasks を使う理由:**

AlertManager は webhook の応答が遅いとタイムアウトエラーとみなす。
Elasticsearch クエリや外部 API 呼び出しは数秒かかるため、
`BackgroundTasks` で非同期に処理し、先に `202 Accepted` を返す。

### Grafana Annotations API

Grafana のグラフ上に「イベント」を時系列で記録する機能。
アラート発生タイミングをメトリクスと重ねて表示できるため原因分析に役立つ。

```
Grafana ダッシュボード (時系列グラフ)

CPU使用率
100% │         ╱╲
 80% │        ╱  ╲
 60% │───────╱    ╲────
     │
     │    ↑ここにアノテーションが表示される
     │    🚨 CPUSpikeHighSustained
     └───────────────────────────→ 時間
```

**API リクエスト例:**

```bash
curl -X POST http://grafana.homelab.local/api/annotations \
  -H "Content-Type: application/json" \
  -u admin:changeme \
  -d '{
    "text": "🚨 CPUSpikeHighSustained\n[状況] ...",
    "tags": ["alert", "aiops", "warning"]
  }'
```

---

## Step 4: 自動修復 (Argo Events + Argo Workflows)

### イベント駆動アーキテクチャ

「何かが起きたら自動で動く」仕組みをイベント駆動という。
このラボでは AlertManager → Argo Events → Argo Workflows という連鎖で実現する。

```
イベント発生源 (AlertManager)
        ↓ HTTP POST
  Argo Events EventSource (イベント受信口)
        ↓ EventBus (メッセージキュー)
  Argo Events Sensor (ルーティング & フィルタリング)
        ↓ Workflow 起動
  Argo Workflows (実際の修復処理)
```

### Argo Events の構成要素

**EventBus**

EventSource と Sensor の間のメッセージングレイヤー。
このラボでは NATS (軽量メッセージキュー) を使用。

```
EventSource ─→ EventBus (NATS) ─→ Sensor
                  (バッファ)
```

EventBus を挟むことで EventSource と Sensor が疎結合になり、
Sensor が一時的にダウンしていても後からイベントを処理できる。

**EventSource**

外部からのイベントを受け取る入口。HTTP / Kafka / GitHub webhook など多様なソースに対応。

```yaml
# AlertManager からの webhook を受け取る HTTP EventSource
spec:
  webhook:
    oomkilled:
      port: "12000"
      endpoint: /oomkilled   # エンドポイントごとに別イベントとして扱われる
    crashloop:
      port: "12000"
      endpoint: /crashloop
```

**Sensor**

EventBus からイベントを受け取り、条件に応じて Workflow を起動する。

```yaml
spec:
  dependencies:
    - name: oomkilled-dep
      eventSourceName: alertmanager
      eventName: oomkilled          # このイベントを監視
  triggers:
    - template:
        argoWorkflow:
          parameters:
            # イベントのペイロードから値を取り出してワークフローのパラメータにセット
            - src:
                dataKey: body.alerts.0.labels.namespace
              dest: spec.arguments.parameters.0.value
```

### Argo Workflows の構成要素

**WorkflowTemplate**

再利用可能なワークフロー定義。Sensor が Workflow を作成する際にこのテンプレートを参照する。

```
WorkflowTemplate (定義)    Workflow (実行インスタンス)
  remediate-oomkilled  →  remediate-oomkilled-a1b2c (1回目)
                       →  remediate-oomkilled-x9y8z (2回目)
```

**Steps (シーケンシャル実行)**

```yaml
templates:
  - name: main
    steps:
      - - name: step1    # フェーズ1
          template: do-something
      - - name: step2    # step1 完了後に実行
          template: notify
          arguments:
            parameters:
              - name: result
                value: "{{steps.step1.outputs.result}}"  # 前ステップの出力を受け取る
```

**Script テンプレート**

コンテナ内でスクリプトを実行するテンプレート。
Kubernetes API を操作する Python コードをインラインで記述できる。

```yaml
- name: patch-memory
  script:
    image: harbor.homelab.local/library/remediation-runner:latest
    command: [python3]
    env:
      - name: NAMESPACE
        value: "{{workflow.parameters.namespace}}"
    source: |
      from kubernetes import client, config
      config.load_incluster_config()
      # ... Kubernetes API を使った処理
```

### OOMKilled 自動修復の仕組み

OOMKill は「コンテナがメモリ上限を超えてカーネルに強制終了させられる」現象。

```
カーネルの OOM Killer:
  コンテナが limit を超えて確保しようとした
    → カーネルが SIGKILL で強制終了
    → kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1

自動修復ワークフロー:
  Pod → ownerReferences → ReplicaSet → ownerReferences → Deployment
                                                              ↓
                                                 memory limit を 1.5 倍にパッチ
```

**Pod のオーナー参照チェーン:**

```python
pod = v1.read_namespaced_pod(pod_name, namespace)
rs_name = [r.name for r in pod.metadata.owner_references if r.kind == "ReplicaSet"][0]

rs = apps_v1.read_namespaced_replica_set(rs_name, namespace)
deploy_name = [r.name for r in rs.metadata.owner_references if r.kind == "Deployment"][0]
```

Deployment → ReplicaSet → Pod という管理階層があるため、
Pod の名前から直接 Deployment を特定することはできず、2段階の参照が必要。

### CrashLoopBackOff 分析の仕組み

CrashLoopBackOff は「コンテナが起動直後にクラッシュして再起動を繰り返す」状態。
Kubernetes はバックオフ (待機時間を指数的に延長) しながら再試行する。

```
再起動回数  次の再起動まで
    1        10秒
    2        20秒
    3        40秒
    4        80秒
    ...       ...
   ∞     最大 5分 (CrashLoopBackOff)
```

**ログ取得の `previous` フラグ:**

```python
# 現在動作中のコンテナのログ (起動直後でログがない場合がある)
v1.read_namespaced_pod_log(pod, ns, previous=False)

# 直前にクラッシュしたコンテナのログ (クラッシュ直前の出力が含まれる)
v1.read_namespaced_pod_log(pod, ns, previous=True)
```

CrashLoopBackOff ではコンテナが停止しているため `previous=True` でクラッシュ直前のログを取得する。

**正規表現エラーパターン分類:**

```python
ERROR_PATTERNS = {
    "OOMKilled":  [r"out of memory", r"Cannot allocate memory"],
    "設定エラー":  [r"config.*error", r"required.*missing"],
    "接続エラー":  [r"connection refused", r"no such host"],
    "権限エラー":  [r"permission denied", r"unauthorized"],
    "パニック":    [r"panic:", r"fatal error:"],
    "起動失敗":    [r"failed to start", r"exec format error"],
}
```

よく見られるエラーパターンを事前定義しておくことで、LLM を使わずに原因を分類できる。

### RBAC 設計

ワークフローが Kubernetes API を操作するには適切な RBAC が必要。

```
remediation-workflow (ServiceAccount in aiops)
  → ClusterRole: pods/log 読み取り、deployments パッチ
  → ワークフロー実行コンテナがこの SA で動作

argo-events-sensor (ServiceAccount in argo-events)
  → Role in aiops: workflows 作成権限
  → Sensor がこの SA で Workflow オブジェクトを作成
```

最小権限の原則 (Principle of Least Privilege):
- `remediation-workflow` は `deployments` の `patch` だけ許可 (delete は不要)
- `argo-events-sensor` は `workflows` の `create` だけ許可

---

## 全体アーキテクチャまとめ

```
┌─────────────────────────────────────────────────────────────────┐
│                        既存スタック                              │
│  Prometheus ─ AlertManager ─ Grafana                            │
│  Elasticsearch ─ Fluent-bit                                      │
└───────────┬──────────────────────────────────────────────────────┘
            │
            ▼
┌─────────────────────────────────────────────────────────────────┐
│                      AIOps 追加コンポーネント                     │
│                                                                   │
│  Step 1: PrometheusRule                                          │
│    predict_linear() ─→ ディスク/メモリ枯渇を24h前に予測           │
│    rate() / increase() ─→ CPU スパイク・Pod 再起動トレンド検知    │
│    AlertManager inhibit_rules ─→ アラートノイズ抑制               │
│                                                                   │
│  Step 2: CronJob (5分ごと)                                       │
│    Elasticsearch ─→ ADTK 異常検知 ─→ Pushgateway ─→ Grafana     │
│                                                                   │
│  Step 3: alert-summarizer (FastAPI Pod)                          │
│    AlertManager webhook ─→ Grafana Annotation 記録               │
│                                                                   │
│  Step 4: Argo Events + Argo Workflows                            │
│    OOMKilled    ─→ Deployment メモリリミット自動増加              │
│    CrashLoopBackOff ─→ ログ収集・エラーパターン分析              │
└─────────────────────────────────────────────────────────────────┘
```

---

## ファイル構成と各ファイルのコード解説

### ファイル構成一覧

```
k8s/aiops/
├── GUIDE.md                              # 本ドキュメント (概念説明・学習用)
├── README.md                             # 操作手順・デプロイ手順
│
├── alerting/                             # 予測アラート定義
│   ├── prometheusrule.yaml               # PrometheusRule (予測・トレンド・自動修復トリガー)
│   └── alertmanager-config.yaml          # AlertManager 設定スニペット (参照用)
│
├── anomaly-detection/                    # ログ異常検知
│   ├── namespace.yaml                    # aiops namespace 定義
│   ├── cronjob.yaml                      # 5分ごとの異常検知 CronJob
│   ├── detector/                         # 異常検知コンテナのソースコード
│   │   ├── Dockerfile                    # コンテナイメージ定義
│   │   ├── detect.py                     # ADTK による異常検知スクリプト
│   │   └── requirements.txt              # Python 依存パッケージ
│   ├── pushgateway/                      # Pushgateway Helm values
│   │   └── values.yaml                   # ServiceMonitor 設定含む
│   └── kaniko-job.yaml                   # (旧) 手動ビルド用 Job (現在は image-build/ に統合)
│
├── alert-summarizer/                     # アラート要約・Grafana 通知
│   ├── deployment.yaml                   # Deployment + Service + Ingress
│   ├── secret.yaml                       # Secret テンプレート (参照用)
│   ├── kaniko-job.yaml                   # (旧) 手動ビルド用 Job
│   └── app/                              # FastAPI アプリのソースコード
│       ├── Dockerfile                    # コンテナイメージ定義
│       ├── app.py                        # webhook 受信 → Grafana Annotation 記録
│       └── requirements.txt              # Python 依存パッケージ
│
├── auto-remediation/                     # 自動修復システム
│   ├── rbac.yaml                         # ServiceAccount / ClusterRole / Role 定義
│   ├── kaniko-job.yaml                   # (旧) 手動ビルド用 Job
│   ├── runner/                           # 修復用コンテナのソースコード
│   │   ├── Dockerfile                    # kubernetes Python クライアント入り
│   │   └── requirements.txt              # Python 依存パッケージ
│   ├── argo-events/                      # イベント駆動基盤
│   │   ├── eventbus.yaml                 # NATS メッセージバス
│   │   ├── event-source.yaml             # AlertManager webhook 受信エンドポイント
│   │   ├── sensor-oomkilled.yaml         # OOMKilled → remediate-oomkilled 起動
│   │   ├── sensor-crashloop.yaml         # CrashLoop → analyze-crashloop 起動
│   │   └── sensor-longhorn-faulted.yaml  # Longhorn faulted → remediate-longhorn-faulted 起動
│   └── argo-workflows/                   # 修復ワークフロー定義
│       ├── workflow-oomkilled.yaml       # メモリリミット 1.5 倍増加
│       ├── workflow-crashloop.yaml       # ログ収集・エラーパターン分析
│       ├── workflow-longhorn-faulted.yaml # Longhorn ボリューム復旧
│       ├── cronworkflow-longhorn-cleanup.yaml          # 定期 Longhorn クリーンアップ
│       └── cronworkflow-cilium-longhorn-sync.yaml      # Cilium-Longhorn 同期
│
└── image-build/                          # CI イメージビルド
    ├── workflow-template.yaml            # Kaniko ビルド WorkflowTemplate (再利用可能)
    └── cronworkflow.yaml                 # 毎日 03:00 JST 全イメージ並列ビルド
```

---

### alerting/ の解説

#### prometheusrule.yaml

**概要:** Prometheus が評価するアラートルールの定義ファイル。予測型アラート、トレンド検知、自動修復トリガーなど全てのカスタムアラートがここに集約されている。

**ファイルパス:** `k8s/aiops/alerting/prometheusrule.yaml`

**基本構造:**

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: aiops-predictive-alerts
  namespace: monitoring
  labels:
    release: monitoring   # kube-prometheus-stack の ruleSelector に合致させるためのラベル
```

`labels.release: monitoring` は重要で、kube-prometheus-stack の Prometheus Operator がこのラベルを持つ PrometheusRule だけをスクレイプ対象として認識する。このラベルがないとルールが Prometheus に読み込まれない。

**ルールグループ一覧と各 PromQL の解説:**

| グループ名 | 評価間隔 | 目的 |
|-----------|---------|------|
| `aiops.disk.prediction` | 5m | ディスク枯渇予測 |
| `aiops.cpu.trend` | 1m | CPU 使用率トレンド |
| `aiops.memory.trend` | 5m | メモリ枯渇予測 |
| `aiops.pod.restarts` | 1m | Pod 再起動率 |
| `aiops.remediation` | 1m | 自動修復トリガー |
| `aiops.longhorn.volume` | 1m | Longhorn ストレージ異常 |
| `aiops.prometheus.storage` | 5m | Prometheus PVC 使用率 |

**1. DiskSpaceExhaustionIn24h (ディスク枯渇24時間前予測)**

```promql
predict_linear(
  node_filesystem_avail_bytes{
    job="node-exporter",
    fstype!~"tmpfs|overlay|squashfs"    # tmpfs 等の仮想ファイルシステムを除外
  }[4h],    # 過去4時間のデータを回帰の入力にする
  86400     # 86400秒 = 24時間後の値を予測
) < 0       # 予測値が0未満 = 24時間以内に枯渇する
```

- `node_filesystem_avail_bytes`: 各マウントポイントの空き容量 (バイト)
- `fstype!~"tmpfs|overlay|squashfs"`: コンテナオーバーレイや tmpfs は物理ディスクではないので除外
- `for: 15m`: 15分間継続して条件を満たした場合のみ発火 (一時的スパイクの誤検知を防ぐ)
- `severity: warning`: 24時間あれば対処の余裕があるため warning

**2. DiskSpaceExhaustionIn4h (ディスク枯渇4時間前予測)**

```promql
predict_linear(
  node_filesystem_avail_bytes{...}[4h], 14400  # 14400秒 = 4時間後
) < 0
```

- 24h版と同じロジックだが予測期間を4時間に短縮
- `severity: critical`: 緊急度が高いため critical
- `for: 10m`: より短い待機時間で素早く通知

**3. CPUSpikeHighSustained (CPU 高負荷持続)**

```promql
(
  1 - avg by(instance) (
    rate(node_cpu_seconds_total{mode="idle"}[5m])
  )
) > 0.85
```

- `node_cpu_seconds_total{mode="idle"}`: CPU がアイドル状態だった秒数 (カウンター)
- `rate(...[5m])`: 直近5分間の1秒あたりアイドル率
- `1 - avg by(instance)(...)`: アイドル率を使用率に反転 (全CPUコアの平均)
- `> 0.85`: 85%超で発火
- `for: 10m`: 10分以上持続した場合のみ (短時間のビルド処理等を除外)

**4. CPUSpikeIncreaseRapid (CPU 使用量急増)**

```promql
increase(
  node_cpu_seconds_total{mode!="idle", job="node-exporter"}[10m]
) > 500
```

- `mode!="idle"`: アイドル以外の全モード (user, system, iowait 等) の合計
- `increase(...[10m])`: 過去10分間で増加した CPU 秒数の合計
- `> 500`: 10分間で500CPU秒の増加は異常 (マルチコアの合計なので正常時でも数十は発生する)

**5. MemoryExhaustionIn2h (メモリ枯渇2時間前予測)**

```promql
predict_linear(
  node_memory_MemAvailable_bytes{job="node-exporter"}[1h], 7200
) < 0
```

- `node_memory_MemAvailable_bytes`: カーネルが報告する「実際に使える」メモリ (キャッシュ含む)
- `[1h]`: メモリはディスクより急変しやすいため回帰窓を短く設定
- `7200`: 2時間後の予測 (メモリ枯渇はディスクより即座に OOM を引き起こすため短い予測)

**6. NodeMemoryPressureHigh (メモリ残量10%未満)**

```promql
(
  node_memory_MemAvailable_bytes{job="node-exporter"}
  / node_memory_MemTotal_bytes{job="node-exporter"}
) < 0.10
```

- 単純な割合比較。予測ではなく「今まさに危険」な状態を検知する閾値アラート
- `severity: critical`: OOM Kill が差し迫っている

**7. PodRestartRateHigh / PodRestartRateCritical (Pod 再起動率)**

```promql
increase(kube_pod_container_status_restarts_total[1h]) > 3
increase(kube_pod_container_status_restarts_total[30m]) > 5
```

- `kube_pod_container_status_restarts_total`: kube-state-metrics が報告する再起動カウンター
- 1時間で3回以上 = じわじわクラッシュが始まっている警告
- 30分で5回以上 = 明らかに CrashLoopBackOff している

**8. PodOOMKilled (自動修復トリガー)**

```promql
kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1
```

- `kube_pod_container_status_last_terminated_reason`: Pod の最後の終了理由
- `for: 0m`: 即座に発火 (修復を遅延させない)
- `labels.remediation: "oom"`: AlertManager がルーティングに使うラベル

**9. PodCrashLoopBackOff (自動修復トリガー)**

```promql
kube_pod_container_status_waiting_reason{reason="CrashLoopBackOff"} == 1
```

- `for: 2m`: 2分間 CrashLoop 状態が続いた場合のみ (一時的な再起動を除外)
- `labels.remediation: "crashloop"`: AlertManager がルーティングに使うラベル

**10. LonghornVolumeFaulted (Longhorn 自動修復トリガー)**

```promql
longhorn_volume_robustness == 3
```

- Longhorn がエクスポートするメトリクス。`robustness` の値: 0=unknown, 1=healthy, 2=degraded, 3=faulted
- `for: 2m`: Longhorn の自動回復を待つ猶予
- `labels.remediation: "longhorn-faulted"`: 自動修復ルーティング用

**11. LonghornVolumeDegraded (レプリカ不足警告)**

```promql
longhorn_volume_robustness == 2
```

- degraded = レプリカ数が設定値未満だが読み書きは可能
- `for: 15m`: Longhorn の自動再構築を待ってから通知

**12. LonghornNodeStorageLow (ノードストレージ使用率)**

```promql
(longhorn_node_storage_usage_bytes / longhorn_node_storage_capacity_bytes) > 0.80
```

- ノード単位のストレージ使用率。80%を超えると新しいレプリカの配置が困難になる

**13. PrometheusStorageHigh (Prometheus PVC 使用率)**

```promql
(
  kubelet_volume_stats_used_bytes{namespace="monitoring", persistentvolumeclaim=~"prometheus-.*"}
  / kubelet_volume_stats_capacity_bytes{...}
) > 0.80
```

- kubelet が報告する PVC の実使用率
- Prometheus のデータが溢れるとメトリクス収集が停止するため事前に検知

---

#### alertmanager-config.yaml

**概要:** AlertManager の設定方針を示す参照用スニペット。実際の設定は `k8s/monitoring/values.yaml` の `alertmanager.config` セクションに統合されている。

**ファイルパス:** `k8s/aiops/alerting/alertmanager-config.yaml`

**route (ルーティング) の設計:**

```yaml
route:
  group_by: ["namespace", "alertname", "severity"]  # 同一問題を1通知にまとめる
  group_wait: 30s          # グループ形成を30秒待つ (同時発火を束ねる)
  group_interval: 5m       # 同一グループの再通知間隔
  repeat_interval: 4h      # 解消されないアラートの再送間隔
  receiver: "null"         # デフォルト受信先 (Slack 未設定のため null)
  routes:
    - matchers:
        - alertname = "Watchdog"    # Watchdog は死活監視用ダミーなので無視
      receiver: "null"
    - matchers:
        - severity = "critical"     # critical は専用チャネルへ (将来 Slack 連携)
      receiver: "null"
      continue: false               # マッチしたらここで終了 (後続ルートを評価しない)
    - matchers:
        - severity = "warning"
      receiver: "null"
      continue: false
```

- `group_by`: namespace + alertname + severity の組み合わせが同じアラートを1通知にまとめる。例えば同じ namespace で同じアラートが10 Pod 分発火しても1通にまとまる
- `group_wait: 30s`: アラート発火後30秒間は同一グループの追加アラートを待ってからまとめて送信する
- `continue: false`: 最初にマッチしたルートで処理を終了し、後続ルートには流さない

**inhibit_rules (抑制ルール) の設計:**

```yaml
inhibit_rules:
  # ルール1: ノードダウン時の副作用アラートを抑制
  - source_matchers:
      - alertname = "NodeNotReady"           # 原因アラート (ノードがダウン)
    target_matchers:
      - alertname =~ "Pod.*|Container.*|Kube.*"  # 抑制される副作用アラート
    equal: ["node"]                          # 同じノードに関するものだけ抑制

  # ルール2: Critical が出ている場合、同一対象の Warning を抑制
  - source_matchers:
      - severity = "critical"
    target_matchers:
      - severity = "warning"
    equal: ["alertname", "namespace", "instance"]  # 完全一致するものだけ

  # ルール3: Watchdog は他に影響させない
  - source_matchers:
      - alertname = "Watchdog"
    target_matchers:
      - alertname != "Watchdog"
```

- ルール1の意図: ノードがダウンすればそのノード上の全 Pod が NotReady になるのは当然。根本原因 (NodeNotReady) だけ通知すれば十分
- ルール2の意図: 例えばディスクの critical (4h枯渇) と warning (24h枯渇) が同時に発火した場合、critical だけ通知すれば十分
- `equal` フィールド: 指定したラベルが一致する場合のみ抑制が適用される (別ノードの問題まで抑制しない)

---

### anomaly-detection/ の解説

#### namespace.yaml

**ファイルパス:** `k8s/aiops/anomaly-detection/namespace.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: aiops
```

AIOps 全コンポーネントが動作する `aiops` namespace を定義するシンプルなマニフェスト。ArgoCD がこの namespace を先に作成してから他のリソースをデプロイする。

---

#### cronjob.yaml

**概要:** 5分ごとに Elasticsearch からログを取得し、ADTK で異常検知を実行し、結果を Pushgateway に送信する CronJob。

**ファイルパス:** `k8s/aiops/anomaly-detection/cronjob.yaml`

**全体の動作フロー:**

```
[CronJob: 5分ごと起動]
    │
    ▼
[コンテナ: anomaly-detector]
    │
    ├─ ES_URL に接続して fluent-bit-* インデックスからログを取得
    │  (過去 LOOKBACK_HOURS 時間分)
    │
    ├─ ADTK (InterQuartileRangeAD / LevelShiftAD) で異常スコアを計算
    │
    └─ PUSHGATEWAY_URL に異常スコアを Push
         │
         ▼
    [Prometheus がスクレイプ → Grafana で可視化]
```

**各フィールドの解説:**

```yaml
spec:
  schedule: "*/5 * * * *"          # cron 式: 毎時 0, 5, 10, ... 分に実行
  concurrencyPolicy: Forbid         # 前回の Job がまだ実行中の場合は新規起動しない
                                    # (二重実行による Elasticsearch 負荷増加を防止)
  successfulJobsHistoryLimit: 3     # 成功した Job Pod を3つまで保持 (ログ確認用)
  failedJobsHistoryLimit: 3         # 失敗した Job Pod を3つまで保持 (デバッグ用)
```

**`backoffLimit: 1` の意味:**

Job が失敗した場合に最大1回だけリトライする。異常検知は5分ごとに再実行されるため、過度なリトライは不要。

**環境変数の役割:**

| 環境変数 | 値 | 説明 |
|---------|-----|------|
| `ES_URL` | `http://elasticsearch-master.logging.svc.cluster.local:9200` | Elasticsearch のクラスタ内 Service URL |
| `PUSHGATEWAY_URL` | `http://aiops-pushgateway-prometheus-pushgateway.monitoring.svc.cluster.local:9091` | メトリクス送信先の Pushgateway Service URL |
| `LOOKBACK_HOURS` | `6` | 異常検知に使う過去データの時間幅 (6時間) |
| `WINDOW_MINUTES` | `5` | 集計の時間窓 (5分単位でログ件数を集計) |
| `ES_INDEX_PATTERN` | `fluent-bit-*` | 検索対象の Elasticsearch インデックスパターン |

**リソース制限:**

```yaml
resources:
  requests:
    cpu: 100m       # 最低 0.1 CPU コア確保
    memory: 256Mi   # 最低 256MB メモリ確保
  limits:
    cpu: 500m       # 最大 0.5 CPU コア (ADTK の計算処理用)
    memory: 512Mi   # 最大 512MB (pandas DataFrame がメモリを使うため)
```

**`imagePullSecrets`:**

```yaml
imagePullSecrets:
  - name: harbor-registry-secret   # Harbor プライベートレジストリの認証情報
```

コンテナイメージは `harbor.homelab.local/library/anomaly-detector:latest` にあるため、Harbor へのログイン認証が必要。

---

#### pushgateway/values.yaml

**概要:** Prometheus Pushgateway の Helm chart 用 values ファイル。CronJob から Push されたメトリクスを Prometheus がスクレイプするための中継点。

**ファイルパス:** `k8s/aiops/anomaly-detection/pushgateway/values.yaml`

```yaml
resources:
  requests:
    cpu: 50m       # 軽量コンポーネントなので最小限
    memory: 64Mi
  limits:
    cpu: 100m
    memory: 128Mi

serviceMonitor:
  enabled: true              # ServiceMonitor CRD を自動生成
  namespace: monitoring      # monitoring namespace に作成 (Prometheus がここを監視)
  additionalLabels:
    release: monitoring      # kube-prometheus-stack の serviceMonitorSelector と一致させる
```

**ServiceMonitor の仕組み:**

```
Pushgateway Pod (monitoring namespace にある ServiceMonitor で発見される)
     ↑
Prometheus Operator が ServiceMonitor を検出
     ↑
ServiceMonitor の selector が Pushgateway Service にマッチ
     ↑
labels.release: monitoring が kube-prometheus-stack の設定と一致
```

`release: monitoring` ラベルがないと Prometheus Operator はこの ServiceMonitor を無視する。これは kube-prometheus-stack の Helm chart がデフォルトで `serviceMonitorSelector.matchLabels.release: monitoring` を設定しているため。

---

### alert-summarizer/ の解説

#### deployment.yaml

**概要:** 3つのリソース (Service, Deployment, Ingress) を1ファイルにまとめたマニフェスト。AlertManager からの webhook を受信し、ログ収集・要約を行い Grafana Annotation に記録する FastAPI サーバー。

**ファイルパス:** `k8s/aiops/alert-summarizer/deployment.yaml`

**Service:**

```yaml
apiVersion: v1
kind: Service
metadata:
  name: alert-summarizer
  namespace: aiops
spec:
  selector:
    app: alert-summarizer    # Deployment の Pod を選択するラベル
  ports:
    - port: 8080             # Service のポート (クラスタ内からのアクセス用)
      targetPort: 8080       # コンテナのポートに転送
```

AlertManager からは `http://alert-summarizer.aiops.svc.cluster.local:8080/webhook` としてアクセスされる。

**Deployment:**

```yaml
spec:
  replicas: 1    # 1台のみ (ラボ環境でリソース節約。HA 不要)
```

**nodeAffinity の設計:**

```yaml
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: node-role.kubernetes.io/control-plane
              operator: DoesNotExist     # コントロールプレーンノードにはスケジュールしない
```

k3s-master には NoSchedule taint が設定されているが、念のため nodeAffinity でも明示的にワーカーノードのみに配置する。

**envFrom と env の使い分け:**

```yaml
envFrom:
  - secretRef:
      name: alert-summarizer-secret  # Secret の全キーを環境変数として注入
env:
  - name: ES_URL                     # 個別の環境変数を直接指定
    value: "http://elasticsearch-master.logging.svc.cluster.local:9200"
```

- `envFrom`: Secret に含まれる `GRAFANA_PASSWORD` と `SLACK_WEBHOOK_URL` をまとめて注入
- `env`: 固定値や Service URL など Secret にする必要がない値を直接指定

**環境変数一覧:**

| 環境変数 | ソース | 説明 |
|---------|--------|------|
| `GRAFANA_PASSWORD` | Secret | Grafana admin パスワード (Annotation API 認証用) |
| `SLACK_WEBHOOK_URL` | Secret | Slack 通知用 URL (オプション。空でも動作する) |
| `ES_URL` | env 直書き | Elasticsearch 接続先 |
| `GRAFANA_URL` | env 直書き | Grafana API エンドポイント |
| `GRAFANA_USER` | env 直書き | Grafana ユーザー名 (admin) |
| `ES_INDEX_PATTERN` | env 直書き | Elasticsearch 検索対象インデックス |
| `LOG_LOOKBACK_MINUTES` | env 直書き | アラート発火時に遡るログの時間幅 (15分) |
| `MAX_LOG_SAMPLES` | env 直書き | Grafana Annotation に含めるログサンプル数上限 (20) |

**ヘルスチェック:**

```yaml
livenessProbe:
  httpGet:
    path: /health           # FastAPI の GET /health エンドポイント
    port: 8080
  initialDelaySeconds: 15   # 起動後15秒待ってからチェック開始
  periodSeconds: 30         # 30秒ごとにチェック

readinessProbe:
  httpGet:
    path: /health
    port: 8080
  initialDelaySeconds: 5    # 起動後5秒でトラフィック受付開始判定
  periodSeconds: 10         # 10秒ごとにチェック
```

- `livenessProbe`: 失敗するとコンテナが再起動される (プロセスがハングした場合の自動復旧)
- `readinessProbe`: 失敗すると Service のエンドポイントから除外される (起動中はトラフィックを受けない)

**Ingress:**

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: alert-summarizer
  namespace: aiops
spec:
  ingressClassName: traefik     # k3s デフォルトの Ingress Controller
  rules:
    - host: alert-summarizer.homelab.local    # Windows hosts ファイルで名前解決
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: alert-summarizer
                port:
                  number: 8080
```

外部 (Windows ブラウザ) から `http://alert-summarizer.homelab.local` でアクセス可能にする。主にデバッグや手動テスト用。

---

#### secret.yaml

**概要:** alert-summarizer が使用するシークレットのテンプレート。実際のデプロイ時は `kubectl create secret` コマンドで作成する。

**ファイルパス:** `k8s/aiops/alert-summarizer/secret.yaml`

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: alert-summarizer-secret
  namespace: aiops
type: Opaque
stringData:
  GRAFANA_PASSWORD: "changeme"   # Grafana admin パスワード (実環境で変更必須)
  SLACK_WEBHOOK_URL: ""          # Slack 連携する場合に URL を設定
```

**重要なポイント:**

- このファイルは **参照用テンプレート** であり、Git にはプレースホルダ値がコミットされている
- 本番シークレットは `kubectl create secret` コマンドで直接作成する (Git に秘密値をコミットしない)
- `stringData` フィールドを使っているため、値は base64 エンコードせずにそのまま書ける (Kubernetes が自動でエンコードする)
- `SLACK_WEBHOOK_URL` が空文字の場合、alert-summarizer は Slack 通知をスキップする

---

### auto-remediation/ の解説

#### rbac.yaml

**概要:** 自動修復システムが Kubernetes API を操作するために必要な権限定義。2つの ServiceAccount と対応する Role/ClusterRole を定義する。

**ファイルパス:** `k8s/aiops/auto-remediation/rbac.yaml`

**全体構成:**

```
┌─────────────────────────────────────────────────────────────────┐
│ ServiceAccount: remediation-workflow (namespace: aiops)          │
│   → ClusterRole: remediation-workflow                           │
│   → ClusterRoleBinding: remediation-workflow                    │
│   用途: ワークフローコンテナが Pod/Deployment/Longhorn を操作    │
├─────────────────────────────────────────────────────────────────┤
│ ServiceAccount: argo-events-sensor (namespace: argo-events)     │
│   → Role: argo-events-sensor-workflow-submit (namespace: aiops) │
│   → RoleBinding: argo-events-sensor-workflow-submit             │
│   用途: Sensor が aiops namespace に Workflow を作成            │
└─────────────────────────────────────────────────────────────────┘
```

**remediation-workflow ClusterRole の権限詳細:**

| apiGroups | resources | verbs | 用途 |
|-----------|-----------|-------|------|
| `""` (core) | pods, pods/log, events | get, list, watch, delete | Pod ログ取得、Pod 削除 (instance-manager 再起動) |
| `apps` | deployments, replicasets, daemonsets, statefulsets | get, list, patch, watch | Deployment のメモリリミットパッチ、オーナー参照の追跡 |
| `longhorn.io` | volumes, replicas, engines, nodes | get, list, watch, patch, update | Longhorn ボリュームの状態確認と修復操作 |
| `storage.k8s.io` | volumeattachments | get, list, watch, delete | stale VolumeAttachment の削除 |

**ClusterRole vs Role の使い分け:**

- `remediation-workflow` は **ClusterRole**: 全 namespace の Pod/Deployment を修復するため (namespace を限定できない)
- `argo-events-sensor-workflow-submit` は **Role** (namespace: aiops): Workflow 作成権限は aiops namespace のみに限定

**argo-events-sensor の権限:**

```yaml
rules:
  - apiGroups: ["argoproj.io"]
    resources: ["workflows"]
    verbs: ["create", "get", "list"]   # Workflow の作成と状態確認のみ
```

最小権限の原則に従い、Sensor は Workflow の `create` と `get/list` (状態確認) のみ許可。`delete` や `patch` は不要。

**RoleBinding の cross-namespace 参照:**

```yaml
kind: RoleBinding
metadata:
  namespace: aiops              # この Role は aiops namespace にある
subjects:
  - kind: ServiceAccount
    name: argo-events-sensor
    namespace: argo-events      # しかし Subject は argo-events namespace の SA
```

RoleBinding の subjects で別 namespace の ServiceAccount を指定することで、cross-namespace のアクセス許可を実現している。

---

#### argo-events/ の解説

##### eventbus.yaml

**概要:** Argo Events の内部メッセージングレイヤー。EventSource と Sensor の間でイベントを中継する。

**ファイルパス:** `k8s/aiops/auto-remediation/argo-events/eventbus.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: EventBus
metadata:
  name: default           # "default" は Argo Events が自動参照する特別な名前
  namespace: argo-events
spec:
  nats:
    native:
      replicas: 1         # NATS サーバーのレプリカ数 (ラボ環境のため1台)
      auth: none          # 認証なし (クラスタ内通信のため)
```

**設計判断:**

- `name: default`: Argo Events は EventBus 名を明示指定しない場合 `default` を使用する。全ての EventSource と Sensor がこの EventBus を暗黙的に参照する
- `replicas: 1`: 本番環境では3以上が推奨だが、ラボ環境ではリソース節約のため1台
- `auth: none`: EventBus は namespace 内通信のみ。外部公開しないため認証不要
- NATS を選択した理由: 軽量 (数十MB) で Argo Events にネイティブ対応。Kafka は過剰

##### event-source.yaml

**概要:** AlertManager からの webhook を受信する HTTP エンドポイント定義。障害の種類ごとに別のエンドポイントを公開する。

**ファイルパス:** `k8s/aiops/auto-remediation/argo-events/event-source.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: EventSource
metadata:
  name: alertmanager
  namespace: argo-events
spec:
  service:
    ports:
      - port: 12000
        targetPort: 12000    # EventSource Pod がリッスンするポート
  webhook:
    oomkilled:                # イベント名 (Sensor がこの名前で購読する)
      port: "12000"
      endpoint: /oomkilled   # HTTP エンドポイントパス
      method: POST
    crashloop:
      port: "12000"
      endpoint: /crashloop
      method: POST
    longhorn-faulted:
      port: "12000"
      endpoint: /longhorn-faulted
      method: POST
```

**自動生成される Service:**

Argo Events は EventSource をデプロイすると自動で Kubernetes Service を生成する:
`alertmanager-eventsource-svc.argo-events.svc.cluster.local:12000`

AlertManager はこの Service の各エンドポイントに POST する。

**AlertManager との連携:**

AlertManager の `webhook_configs` から以下のように呼ばれる:

```
PodOOMKilled 発火
  → AlertManager が route で remediation ラベルを判定
  → POST http://alertmanager-eventsource-svc.argo-events.svc.cluster.local:12000/oomkilled
  → EventSource がイベントを EventBus に発行
```

**エンドポイントを分ける理由:**

1つのエンドポイントでも AlertManager のペイロードから分岐できるが、エンドポイントを分けることで:
- Sensor 側のフィルタリングロジックが不要になる
- 各障害タイプのイベント数を個別に監視できる
- AlertManager 側のルーティングが明確になる

##### sensor-oomkilled.yaml

**概要:** EventBus の `oomkilled` イベントを監視し、`remediate-oomkilled` WorkflowTemplate を起動する Sensor。

**ファイルパス:** `k8s/aiops/auto-remediation/argo-events/sensor-oomkilled.yaml`

```yaml
spec:
  template:
    serviceAccountName: argo-events-sensor  # Workflow 作成権限を持つ SA
  dependencies:
    - name: oomkilled-dep
      eventSourceName: alertmanager         # EventSource の name
      eventName: oomkilled                  # webhook セクションのキー名
  triggers:
    - template:
        name: trigger-oomkilled-workflow
        argoWorkflow:
          operation: submit                 # Workflow を新規作成して実行
          source:
            resource:                       # Workflow のテンプレート (デフォルト値付き)
              apiVersion: argoproj.io/v1alpha1
              kind: Workflow
              metadata:
                generateName: remediate-oomkilled-    # 実行ごとにユニーク名を生成
                namespace: aiops
              spec:
                workflowTemplateRef:
                  name: remediate-oomkilled           # 参照する WorkflowTemplate
                arguments:
                  parameters:
                    - name: namespace
                      value: "default"               # デフォルト値 (上書きされる)
                    - name: pod
                      value: "unknown"
                    - name: container
                      value: "unknown"
          parameters:                                # イベントペイロードからパラメータを抽出
            - src:
                dependencyName: oomkilled-dep
                dataKey: body.alerts.0.labels.namespace   # AlertManager JSON の階層指定
              dest: spec.arguments.parameters.0.value     # Workflow パラメータにセット
            - src:
                dependencyName: oomkilled-dep
                dataKey: body.alerts.0.labels.pod
              dest: spec.arguments.parameters.1.value
            - src:
                dependencyName: oomkilled-dep
                dataKey: body.alerts.0.labels.container
              dest: spec.arguments.parameters.2.value
```

**`parameters` のデータマッピング:**

AlertManager が送信する JSON:
```json
{
  "body": {
    "alerts": [
      {
        "labels": {
          "namespace": "default",     → dataKey: body.alerts.0.labels.namespace
          "pod": "my-app-xyz-abc",    → dataKey: body.alerts.0.labels.pod
          "container": "main"         → dataKey: body.alerts.0.labels.container
        }
      }
    ]
  }
}
```

`dest: spec.arguments.parameters.0.value` は Workflow の arguments.parameters 配列の0番目の value フィールドを上書きする。

##### sensor-crashloop.yaml

**概要:** `crashloop` イベントを受信して `analyze-crashloop` WorkflowTemplate を起動する。構造は sensor-oomkilled.yaml とほぼ同じ。

**ファイルパス:** `k8s/aiops/auto-remediation/argo-events/sensor-crashloop.yaml`

sensor-oomkilled.yaml との違い:
- `eventName: crashloop` (監視するイベント)
- `generateName: analyze-crashloop-` (Workflow の名前プレフィックス)
- `workflowTemplateRef.name: analyze-crashloop` (参照するテンプレート)
- 渡すパラメータは同じ (namespace, pod, container)

##### sensor-longhorn-faulted.yaml

**概要:** `longhorn-faulted` イベントを受信して `remediate-longhorn-faulted` WorkflowTemplate を起動する。

**ファイルパス:** `k8s/aiops/auto-remediation/argo-events/sensor-longhorn-faulted.yaml`

他の Sensor との違い:
- `eventName: longhorn-faulted`
- `generateName: remediate-longhorn-faulted-`
- 渡すパラメータは `volume` のみ (Pod 名ではなく Longhorn ボリューム名)

```yaml
parameters:
  - src:
      dependencyName: longhorn-faulted-dep
      dataKey: body.alerts.0.labels.volume    # Longhorn のボリューム名
    dest: spec.arguments.parameters.0.value
```

---

#### argo-workflows/ の解説

##### workflow-oomkilled.yaml (メモリリミット自動増加)

**概要:** OOMKilled された Pod の親 Deployment を特定し、メモリリミットを1.5倍に自動増加する WorkflowTemplate。

**ファイルパス:** `k8s/aiops/auto-remediation/argo-workflows/workflow-oomkilled.yaml`

**処理フロー:**

```
[main]
  │
  ├─ Step 1: patch-memory
  │   ├─ Pod のオーナー参照をたどって Deployment を特定
  │   │   Pod → ownerReferences → ReplicaSet → ownerReferences → Deployment
  │   ├─ 現在のメモリリミットを取得
  │   ├─ 1.5 倍の値を計算 (256Mi → 384Mi)
  │   └─ Deployment に strategic merge patch を適用
  │
  └─ Step 2: notify
      └─ Grafana Annotation API に結果を記録
```

**patch-memory テンプレートの重要ロジック:**

1. **Pod → Deployment の特定 (2段階参照):**
   ```python
   # Pod → ReplicaSet
   pod = v1.read_namespaced_pod(pod_name, namespace)
   rs_name = [ref.name for ref in pod.metadata.owner_references if ref.kind == "ReplicaSet"][0]

   # ReplicaSet → Deployment
   rs = apps_v1.read_namespaced_replica_set(rs_name, namespace)
   deploy_name = [ref.name for ref in rs.metadata.owner_references if ref.kind == "Deployment"][0]
   ```

2. **メモリ値のパース (`parse_mi` 関数):**
   ```python
   def parse_mi(s):
       if not s: return 256              # 未設定の場合は 256Mi をベースに
       m = re.match(r"(\d+)(Mi|Gi|M|G)?", s, re.IGNORECASE)
       val = int(m.group(1))
       unit = (m.group(2) or "").lower()
       return val * 1024 if unit in ("gi", "g") else val  # Gi → Mi に変換
   ```

3. **スキップ条件:**
   - Pod が見つからない場合 (既に削除されている)
   - Pod が ReplicaSet に管理されていない場合 (DaemonSet/StatefulSet は対象外)
   - ReplicaSet が Deployment に管理されていない場合

**notify テンプレート:**

curl を使って Grafana Annotation API に結果を POST。修復を行ったことの証跡を Grafana のタイムライン上に残す。

##### workflow-crashloop.yaml (CrashLoopBackOff 分析)

**概要:** CrashLoopBackOff 状態の Pod からログを収集し、エラーパターンを正規表現で自動分類する WorkflowTemplate。修復は行わず、分析結果の記録に特化している。

**ファイルパス:** `k8s/aiops/auto-remediation/argo-workflows/workflow-crashloop.yaml`

**処理フロー:**

```
[main]
  │
  ├─ Step 1: analyze
  │   ├─ Pod の直前コンテナログを取得 (previous=True)
  │   │   ※ CrashLoop 中は current ログが空のため previous が重要
  │   ├─ Pod の k8s イベントを取得 (直近5件)
  │   ├─ ログを正規表現パターンで分類
  │   │   - OOMKilled / 設定エラー / 接続エラー / 権限エラー / パニック / 起動失敗
  │   └─ レポートを生成して outputs.result に出力
  │
  └─ Step 2: notify
      └─ レポートを Grafana Annotation に記録
```

**ログ取得の `previous=True` フォールバック:**

```python
try:
    logs = v1.read_namespaced_pod_log(pod_name, namespace, previous=True, tail_lines=80)
except Exception:
    logs = v1.read_namespaced_pod_log(pod_name, namespace, tail_lines=80)
```

- `previous=True`: クラッシュ直前のコンテナのログを取得 (本命)
- フォールバック: previous が利用不可の場合 (初回起動失敗等) は current を試行

**エラーパターン辞書:**

```python
ERROR_PATTERNS = {
    "OOMKilled":  [r"OOMKilled", r"out of memory", r"Cannot allocate memory"],
    "設定エラー": [r"config.*error", r"invalid.*config", r"failed to load config",
                  r"environment variable.*not set", r"required.*missing"],
    "接続エラー": [r"connection refused", r"dial tcp", r"no such host",
                  r"connection timed out", r"EOF"],
    "権限エラー": [r"permission denied", r"unauthorized", r"forbidden",
                  r"access denied"],
    "パニック":   [r"panic:", r"fatal error:", r"SIGTERM", r"SIGKILL"],
    "起動失敗":   [r"failed to start", r"failed to initialize", r"Error starting",
                  r"exec format error"],
}
```

各カテゴリの正規表現にマッチした行を最大3つまで抽出し、レポートに含める。LLM を使わずにルールベースで高速に分類できる。

##### workflow-longhorn-faulted.yaml (Longhorn ボリューム復旧)

**概要:** Longhorn の faulted ボリュームを自動修復する WorkflowTemplate。instance-manager の再起動と VolumeAttachment のクリーンアップを行う。

**ファイルパス:** `k8s/aiops/auto-remediation/argo-workflows/workflow-longhorn-faulted.yaml`

**処理フロー:**

```
[main]
  │
  ├─ Step 1: recover-volume (タイムアウト: 300秒)
  │   ├─ [Step 1] stale VolumeAttachment の検出・削除
  │   │   └─ status.attached == false の VolumeAttachment を削除
  │   ├─ [Step 2] Longhorn instance-manager Pod を全削除
  │   │   └─ ラベル longhorn.io/component=instance-manager で選択
  │   └─ [Step 3] ボリューム回復待機 (最大180秒)
  │       └─ 10秒ごとに robustness を確認 → healthy/degraded で成功
  │
  └─ Step 2: notify
      └─ Grafana Annotation に結果を記録
```

**各修復ステップの背景:**

1. **stale VolumeAttachment 削除**: ノードがダウンした場合に古い VolumeAttachment が残り、新しいアタッチを阻害することがある
2. **instance-manager 再起動**: Cilium ローリングリスタート後にネットワーク不整合が発生した場合、instance-manager を再起動することで gRPC 通信を再確立する
3. **回復待機**: Longhorn は instance-manager 再起動後に自動で レプリカ再同期を開始する。healthy または degraded に遷移すれば成功

**`activeDeadlineSeconds: 300`:**

recover-volume テンプレート全体に300秒のタイムアウトを設定。ストレージ修復が無限にハングすることを防ぐ。

---

### image-build/ の解説

#### workflow-template.yaml (Kaniko イメージビルド)

**概要:** Kaniko を使って Git リポジトリからコンテナイメージをビルドし Harbor にプッシュする再利用可能な WorkflowTemplate。

**ファイルパス:** `k8s/aiops/image-build/workflow-template.yaml`

```yaml
apiVersion: argoproj.io/v1alpha1
kind: WorkflowTemplate
metadata:
  name: kaniko-build
  namespace: aiops
spec:
  templates:
    - name: build-and-push
      inputs:
        parameters:
          - name: context-sub-path    # Git リポジトリ内のビルドコンテキスト相対パス
          - name: destination         # プッシュ先のイメージ URL (tag 含む)
```

**Kaniko コンテナの引数解説:**

```yaml
args:
  - "--context=git://github.com/fukui-yuto/proxmox-lab.git#main"
      # Git リポジトリの main ブランチを直接ビルドコンテキストとして使用
  - "--context-sub-path={{inputs.parameters.context-sub-path}}"
      # リポジトリ内のサブディレクトリを指定 (例: k8s/aiops/anomaly-detection/detector)
  - "--dockerfile=Dockerfile"
      # context-sub-path 内の Dockerfile を使用
  - "--destination={{inputs.parameters.destination}}"
      # ビルド後のプッシュ先 (例: harbor.homelab.local/library/anomaly-detector:latest)
  - "--insecure"
      # HTTP レジストリへの接続を許可 (Harbor が HTTP のため)
  - "--skip-tls-verify"
      # TLS 証明書の検証をスキップ
```

**Kaniko を使う理由:**

- Docker デーモンが不要 (Pod 内で完結)
- 特権コンテナ不要 (DinD と異なりセキュリティリスクが低い)
- Kubernetes ネイティブに動作

**Harbor レジストリの認証:**

```yaml
volumes:
  - name: kaniko-secret
    secret:
      secretName: harbor-registry-secret   # docker login 相当の認証情報
      items:
        - key: .dockerconfigjson
          path: config.json
volumeMounts:
  - name: kaniko-secret
    mountPath: /kaniko/.docker              # Kaniko がこのパスの config.json を参照
```

`harbor-registry-secret` は `kubernetes.io/dockerconfigjson` タイプの Secret で、Harbor のログイン情報を格納している。

---

#### cronworkflow.yaml (毎日 03:00 JST 全イメージビルド)

**概要:** 毎日午前3時 (JST) に全 AIOps コンテナイメージを並列ビルドする CronWorkflow。Harbor 再起動時のイメージ消失に対する自動復旧手段。

**ファイルパス:** `k8s/aiops/image-build/cronworkflow.yaml`

```yaml
spec:
  schedule: "0 3 * * *"         # cron 式: 毎日03:00
  timezone: "Asia/Tokyo"         # JST で評価 (UTC だと 18:00 になってしまう)
  concurrencyPolicy: Replace     # 前回がまだ実行中の場合は停止して新規実行に置換
  successfulJobsHistoryLimit: 3  # 成功履歴3つ保持
  failedJobsHistoryLimit: 3      # 失敗履歴3つ保持
```

**DAG (有向非循環グラフ) による並列ビルド:**

```yaml
templates:
  - name: build-all
    dag:
      tasks:
        - name: anomaly-detector     # 3つのタスクは依存関係がないため並列実行
          templateRef:
            name: kaniko-build
            template: build-and-push
          arguments:
            parameters:
              - name: context-sub-path
                value: k8s/aiops/anomaly-detection/detector
              - name: destination
                value: harbor.homelab.local/library/anomaly-detector:latest

        - name: alert-summarizer     # 並列実行
          templateRef: ...
          arguments:
            parameters:
              - name: context-sub-path
                value: k8s/aiops/alert-summarizer/app
              - name: destination
                value: harbor.homelab.local/library/alert-summarizer:latest

        - name: remediation-runner   # 並列実行
          templateRef: ...
          arguments:
            parameters:
              - name: context-sub-path
                value: k8s/aiops/auto-remediation/runner
              - name: destination
                value: harbor.homelab.local/library/remediation-runner:latest
```

**DAG vs Steps の違い:**

- `steps`: 上から順にシーケンシャル実行 (Step1 完了後に Step2)
- `dag`: 依存関係 (`dependencies` フィールド) がないタスクは自動並列実行

3つのイメージビルドは互いに依存しないため、DAG を使うことで並列実行され、ビルド時間が短縮される。

**ビルド対象イメージ一覧:**

| タスク名 | ビルドコンテキスト | プッシュ先 | 用途 |
|---------|-----------------|-----------|------|
| anomaly-detector | `k8s/aiops/anomaly-detection/detector/` | `harbor.homelab.local/library/anomaly-detector:latest` | ログ異常検知 CronJob |
| alert-summarizer | `k8s/aiops/alert-summarizer/app/` | `harbor.homelab.local/library/alert-summarizer:latest` | webhook 受信・Grafana 通知 |
| remediation-runner | `k8s/aiops/auto-remediation/runner/` | `harbor.homelab.local/library/remediation-runner:latest` | OOMKilled/CrashLoop 修復 |

**手動トリガー方法:**

```bash
argo cron trigger build-aiops-images -n aiops
```

Harbor のデータが消失した場合やイメージの更新を即座に反映したい場合に使用する。

---

### 自動修復の全体フロー図

以下に、アラート発火から自動修復完了までの全体フローを ASCII で示す。

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                          Prometheus (メトリクス収集)                           │
│                                                                              │
│  node_exporter / kube-state-metrics / longhorn-exporter                      │
│         │                                                                    │
│         ▼                                                                    │
│  ┌─────────────────────────────────────────────┐                            │
│  │ PrometheusRule (aiops-predictive-alerts)     │                            │
│  │                                             │                            │
│  │  PodOOMKilled                               │                            │
│  │  PodCrashLoopBackOff                        │                            │
│  │  LonghornVolumeFaulted                      │                            │
│  │  DiskSpaceExhaustionIn24h (通知のみ)         │                            │
│  │  CPUSpikeHighSustained   (通知のみ)         │                            │
│  └──────────────────┬──────────────────────────┘                            │
│                     │ アラート発火                                            │
│                     ▼                                                        │
│  ┌─────────────────────────────────────────────┐                            │
│  │ AlertManager                                │                            │
│  │                                             │                            │
│  │  route:                                     │                            │
│  │    remediation=oom       → /oomkilled       │                            │
│  │    remediation=crashloop → /crashloop       │                            │
│  │    remediation=longhorn-faulted             │                            │
│  │                            → /longhorn-faulted                           │
│  │                                             │                            │
│  │  inhibit_rules:                             │                            │
│  │    NodeNotReady → Pod* 抑制                 │                            │
│  │    critical → warning 抑制                  │                            │
│  └──────────────────┬──────────────────────────┘                            │
│                     │ HTTP POST (webhook)                                    │
└─────────────────────┼────────────────────────────────────────────────────────┘
                      │
                      ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                     Argo Events (argo-events namespace)                       │
│                                                                              │
│  ┌────────────────────────┐      ┌──────────────┐                           │
│  │ EventSource            │      │ EventBus     │                           │
│  │ (alertmanager)         │─────→│ (NATS)       │                           │
│  │                        │      │              │                           │
│  │  POST /oomkilled       │      │  イベントを   │                           │
│  │  POST /crashloop       │      │  バッファ     │                           │
│  │  POST /longhorn-faulted│      └──────┬───────┘                           │
│  └────────────────────────┘             │                                    │
│                                         ▼                                    │
│  ┌──────────────────────────────────────────────────────────┐               │
│  │ Sensors                                                   │               │
│  │                                                           │               │
│  │  oomkilled-sensor ──→ submit: remediate-oomkilled-xxxxx   │               │
│  │  crashloop-sensor ──→ submit: analyze-crashloop-xxxxx     │               │
│  │  longhorn-faulted-sensor ──→ submit: remediate-longhorn-faulted-xxxxx    │
│  │                                                           │               │
│  │  (イベントペイロードから namespace/pod/container/volume を抽出)             │
│  └──────────────────────────────────────────────────────────┘               │
└──────────────────────────────────────────────────────────────────────────────┘
                      │
                      │ Workflow 作成 (aiops namespace)
                      ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                     Argo Workflows (aiops namespace)                          │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ remediate-oomkilled                                                  │    │
│  │  1. Pod → ReplicaSet → Deployment を特定                             │    │
│  │  2. メモリリミットを 1.5 倍に patch                                    │    │
│  │  3. Grafana Annotation に記録                                        │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ analyze-crashloop                                                    │    │
│  │  1. Pod ログ取得 (previous=True)                                     │    │
│  │  2. k8s イベント取得                                                  │    │
│  │  3. 正規表現でエラーパターン分類                                        │    │
│  │  4. Grafana Annotation にレポート記録                                  │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │ remediate-longhorn-faulted                                           │    │
│  │  1. stale VolumeAttachment を削除                                    │    │
│  │  2. instance-manager Pod を全削除 (ネットワーク不整合解消)              │    │
│  │  3. ボリューム回復待機 (最大 180 秒)                                   │    │
│  │  4. Grafana Annotation に結果記録                                     │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
                      │
                      │ HTTP POST (Annotation API)
                      ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                     Grafana (monitoring namespace)                            │
│                                                                              │
│  ダッシュボード上に修復実行のタイムスタンプ・結果を表示                          │
│  → 「いつ・何が起きて・何をしたか」が時系列で確認可能                           │
└──────────────────────────────────────────────────────────────────────────────┘
```

**フロー全体のポイント:**

1. **宣言的なアラート定義**: PrometheusRule で PromQL を書くだけでアラートが動作する
2. **疎結合なイベント連鎖**: AlertManager → EventSource → EventBus → Sensor → Workflow の各段が独立しており、個別にテスト・差し替え可能
3. **冪等な修復処理**: OOMKilled の修復は何度実行しても同じ結果 (1.5倍のパッチが重複適用されても動作する)
4. **証跡の記録**: 全ての修復結果が Grafana Annotation に記録され、後から「いつ何をしたか」を確認できる
5. **段階的なエスカレーション**: 自動修復できない場合は TIMEOUT を出力し、人間の手動介入を促す
