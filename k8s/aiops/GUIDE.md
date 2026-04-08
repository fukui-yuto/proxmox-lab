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
