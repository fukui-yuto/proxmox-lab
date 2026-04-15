# AIOps

既存の監視・ログスタックを活用して IT 運用を AI で知能化するコンポーネント群。

---

## ディレクトリ構成

| ディレクトリ | 内容 | 状態 |
|---|---|---|
| `alerting/` | 予測・トレンド型アラートルール (PrometheusRule / AlertManager 設定) | ✅ 完了 |
| `anomaly-detection/` | ログ異常検知 CronJob + Grafana ダッシュボード | ✅ 完了 |
| `alert-summarizer/` | LLM アラートサマリ (Claude API) | ✅ 完了 |
| `auto-remediation/` | 自動修復 Runbook (Argo Events/Workflows) | ✅ 完了 |
| `image-build/` | aiops イメージ自動ビルド CI (Argo Workflows CronWorkflow) | ✅ 完了 |

---

## Step 1: Grafana アラート知能化

### 概要

- `predict_linear()` を使った**予測型アラート** (ディスク・メモリ枯渇を事前検知)
- `rate()` / `increase()` を使った**トレンド型アラート** (CPU スパイク・Pod 再起動率)
- AlertManager の `inhibit_rules` による**ノイズ抑制**

### デプロイ

ArgoCD App `aiops-alerting` が `k8s/aiops/alerting/prometheusrule.yaml` を `monitoring` namespace へ自動適用する。

```bash
# 旧アプリ (aiops-step1-alerting) が残っている場合は削除
kubectl delete application aiops-step1-alerting -n argocd

# ArgoCD App を手動で適用する場合
kubectl apply -f k8s/argocd/apps/aiops.yaml
```

### アラート一覧

| アラート名 | 説明 | Severity |
|---|---|---|
| `DiskSpaceExhaustionIn24h` | ディスク空き容量が24時間以内に枯渇予測 | warning |
| `DiskSpaceExhaustionIn4h` | ディスク空き容量が4時間以内に枯渇予測 | critical |
| `CPUSpikeHighSustained` | CPU 使用率が85%超を10分継続 | warning |
| `CPUSpikeIncreaseRapid` | CPU 使用量が急増 | warning |
| `MemoryExhaustionIn2h` | メモリが2時間以内に枯渇予測 | warning |
| `NodeMemoryPressureHigh` | 空きメモリが10%未満 | critical |
| `PodRestartRateHigh` | Pod が1時間で3回以上再起動 | warning |
| `PodRestartRateCritical` | Pod が30分で5回以上再起動 | critical |
| `PrometheusStorageHigh` | Prometheus PVC 使用率が80%超 | warning |

---

## イメージビルド自動化

### 概要

aiops の各コンポーネントは Harbor の内部イメージを使用する。
これらのイメージは **Argo Workflows CronWorkflow** (`build-aiops-images`) によって毎日 03:00 JST に自動ビルド・push される。

| イメージ | ソース |
|---------|--------|
| `harbor.homelab.local/library/anomaly-detector:latest` | `k8s/aiops/anomaly-detection/detector/` |
| `harbor.homelab.local/library/alert-summarizer:latest` | `k8s/aiops/alert-summarizer/app/` |
| `harbor.homelab.local/library/remediation-runner:latest` | `k8s/aiops/auto-remediation/runner/` |

### 自動ビルドの効果

- **Harbor データ消失時の自動復旧**: Harbor が再起動してイメージが消えても、翌朝 03:00 に自動再ビルドされる
- **コード変更の自動反映**: `main` ブランチへの push 後、翌朝のビルドで Harbor に反映される
- **ArgoCD で宣言的管理**: `aiops-image-build` ArgoCD App が `k8s/aiops/image-build/` を管理

### 手動トリガー (即時ビルドが必要な場合)

```bash
# CronWorkflow を即時実行
argo cron trigger build-aiops-images -n aiops

# または個別イメージだけビルド
argo submit --from workflowtemplate/kaniko-build \
  -p context-sub-path=k8s/aiops/anomaly-detection/detector \
  -p destination=harbor.homelab.local/library/anomaly-detector:latest \
  -n aiops

# ビルド進捗確認 (Argo Workflows UI)
# http://argo-workflows.homelab.local
```

> 緊急時の手動ビルド方法は各サブディレクトリの `kaniko-job.yaml` を参照。

---

## Step 2: ログ異常検知 CronJob

### 概要

Elasticsearch のログを5分ごとに集計し、ADTK (Anomaly Detection Toolkit) で異常を検知。
結果を Prometheus Pushgateway 経由で Grafana に可視化する。

### アーキテクチャ

```
Fluent-bit → Elasticsearch (fluent-bit-* インデックス)
                  ↓ ES Query API (5分ごと)
         [log-anomaly-detector CronJob]
         - InterQuartileRangeAD: 総ログ量の外れ値検知
         - LevelShiftAD: エラーログの急増検知
                  ↓ prometheus_client
         Prometheus Pushgateway → Prometheus → Grafana
```

### 検知メトリクス

| メトリクス名 | 説明 |
|---|---|
| `log_total_count` | 直近ウィンドウの総ログ件数 |
| `log_error_count` | 直近ウィンドウのエラーログ件数 |
| `log_error_rate` | エラーログ率 (errors / total) |
| `log_anomaly_total_detected` | 総ログ量の異常検知フラグ (1=異常) |
| `log_anomaly_error_detected` | エラーログ量の異常検知フラグ (1=異常) |
| `log_anomaly_error_shift_detected` | エラーログの急増フラグ (1=急増) |

### Grafana ダッシュボード

`http://grafana.homelab.local` → **Log Anomaly Detection** ダッシュボードで以下を確認できる。

| パネル | 内容 |
|---|---|
| Total Log Anomaly | 総ログ量の異常フラグ (緑=正常 / 赤=異常) |
| Error Log Anomaly | エラーログ量の異常フラグ |
| Error Log Level-Shift | エラーログの急増フラグ |
| Error Rate | 直近ウィンドウのエラー率 |
| Log Count (Total vs Error) | 総ログ数とエラーログ数の時系列 |
| Error Rate Trend | エラー率の時系列 |
| Anomaly Flags Timeline | 3つの異常フラグの時系列 |

ダッシュボードは `k8s/monitoring/dashboards/log-anomaly-cm.yaml` の ConfigMap (label: `grafana_dashboard=1`) として管理。
ArgoCD monitoring app の sync で自動適用される。

### デプロイ手順

#### 1. Harbor を起動

```bash
kubectl apply -f k8s/argocd/apps/harbor.yaml
# Harbor が Ready になるまで待機 (5〜10分)
kubectl get pods -n harbor -w
```

#### 2. ArgoCD App を適用 (Pushgateway + CronJob namespace)

```bash
kubectl apply -f k8s/argocd/apps/aiops.yaml
```

#### 3. Harbor に anomaly-detector イメージをビルド・push (kaniko)

```bash
# aiops namespace と Harbor 認証 Secret を作成
kubectl apply -f k8s/aiops/anomaly-detection/namespace.yaml
kubectl create secret docker-registry harbor-registry-secret \
  --docker-server=harbor.homelab.local \
  --docker-username=admin \
  --docker-password=Harbor12345 \
  -n aiops

# kaniko Job でイメージをビルド・push
kubectl apply -f k8s/aiops/anomaly-detection/kaniko-job.yaml

# ビルドログを確認
kubectl logs -f job/build-anomaly-detector -n aiops
```

#### 4. CronJob を確認

```bash
# CronJob の状態確認
kubectl get cronjob -n aiops

# 手動実行でテスト
kubectl create job --from=cronjob/log-anomaly-detector test-run -n aiops
kubectl logs -f job/test-run -n aiops

# Pushgateway でメトリクス確認
kubectl port-forward svc/prometheus-pushgateway 9091:9091 -n monitoring
# → http://localhost:9091 でメトリクス確認
```

### 設定値

| 環境変数 | デフォルト | 説明 |
|---|---|---|
| `ES_URL` | `http://elasticsearch-master.logging.svc.cluster.local:9200` | ES エンドポイント |
| `PUSHGATEWAY_URL` | `http://aiops-pushgateway-prometheus-pushgateway.monitoring.svc.cluster.local:9091` | Pushgateway エンドポイント |
| `LOOKBACK_HOURS` | `6` | 過去何時間分のログを集計するか |
| `WINDOW_MINUTES` | `5` | 集計ウィンドウ (分) |
| `ES_INDEX_PATTERN` | `fluent-bit-*` | ES インデックスパターン |

---

## Step 3: LLM アラートサマリ (alert-summarizer)

### 概要

AlertManager がアラートを発火すると webhook で `alert-summarizer` Pod に通知が届く。
Pod は Elasticsearch から直近エラーログを取得し、**Claude API** でサマリを生成。
結果を **Grafana アノテーション**として記録し、オプションで **Slack 通知**も送信する。

### アーキテクチャ

```
AlertManager
    ↓ webhook (HTTP POST /webhook)
[alert-summarizer Pod (FastAPI)]
    ├─ Elasticsearch から直近 15 分のエラーログ取得
    └─ Claude API (claude-haiku-4-5) でサマリ生成
         ↓
    Grafana Annotation API → Grafana 上にアノテーション表示
    Slack Webhook (オプション) → Slack 通知
```

### サマリ出力形式

Claude API が以下の形式で回答を生成する:

```
**[状況]** 何が起きているか (2〜3文)
**[影響]** 影響範囲・サービス
**[次のアクション]** 確認・対処すべき手順 (箇条書き 3項目以内)
```

### デプロイ手順

#### 1. Harbor を起動して alert-summarizer イメージをビルド

```bash
# Harbor が起動済みであることを確認
kubectl get pods -n harbor

# Harbor 認証 Secret (anomaly-detection で作成済みの場合はスキップ)
kubectl create secret docker-registry harbor-registry-secret \
  --docker-server=harbor.homelab.local \
  --docker-username=admin \
  --docker-password=Harbor12345 \
  -n aiops

# kaniko で alert-summarizer イメージをビルド・push
kubectl apply -f k8s/aiops/alert-summarizer/kaniko-job.yaml
kubectl logs -f job/build-alert-summarizer -n aiops
```

#### 2. Secret を作成

```bash
kubectl create secret generic alert-summarizer-secret \
  --from-literal=ANTHROPIC_API_KEY="" \
  --from-literal=GRAFANA_PASSWORD="changeme" \
  --from-literal=SLACK_WEBHOOK_URL="" \
  -n aiops
```

> `ANTHROPIC_API_KEY` は省略可能。未設定の場合はアラートの生データを Grafana アノテーションに記録するフォールバック動作をする。

#### 3. ArgoCD App を sync (Deployment をデプロイ)

```bash
kubectl apply -f k8s/argocd/apps/aiops.yaml
# または ArgoCD UI で aiops-alert-summarizer を手動 Sync
```

#### 4. AlertManager を再起動して webhook 設定を反映

`k8s/monitoring/values.yaml` の AlertManager webhook 設定が monitoring app の sync で反映される。

```bash
# monitoring app を Helm upgrade で更新
kubectl apply -f k8s/argocd/apps/monitoring.yaml
# または ArgoCD UI で monitoring app を Sync
```

#### 5. 動作確認

```bash
# Pod が起動しているか確認
kubectl get pods -n aiops

# ヘルスチェック
kubectl exec -n aiops deploy/alert-summarizer -- curl -s localhost:8080/health

# ログ確認
kubectl logs -f deploy/alert-summarizer -n aiops

# テスト webhook 送信
kubectl exec -n aiops deploy/alert-summarizer -- \
  curl -s -X POST localhost:8080/webhook \
  -H "Content-Type: application/json" \
  -d '{"version":"4","status":"firing","receiver":"alert-summarizer","alerts":[{"status":"firing","labels":{"alertname":"TestAlert","severity":"warning"},"annotations":{"description":"テスト用アラート"},"startsAt":"2024-01-01T00:00:00Z"}]}'
```

### 設定値

| 環境変数 | デフォルト | 説明 |
|---|---|---|
| `ANTHROPIC_API_KEY` | *(空)* | Claude API キー (省略可。未設定時は生アラートデータを Grafana に記録) |
| `GRAFANA_PASSWORD` | *(Secret)* | Grafana admin パスワード |
| `SLACK_WEBHOOK_URL` | *(Secret / 空)* | Slack Incoming Webhook URL (オプション) |
| `ES_URL` | `http://elasticsearch-master.logging.svc.cluster.local:9200` | ES エンドポイント |
| `GRAFANA_URL` | `http://monitoring-grafana.monitoring.svc.cluster.local` | Grafana エンドポイント |
| `GRAFANA_USER` | `admin` | Grafana ユーザー名 |
| `CLAUDE_MODEL` | `claude-haiku-4-5-20251001` | 使用する Claude モデル |
| `LOG_LOOKBACK_MINUTES` | `15` | ES から取得するログの遡り時間 |
| `MAX_LOG_SAMPLES` | `20` | ES から取得するログサンプル数上限 |

---

## Step 4: 自動修復 Runbook (auto-remediation)

### 概要

障害アラートを Argo Events が受信し、Argo Workflows で自動修復アクションを実行する。
Claude API は使用せず、正規表現によるパターン分析で動作する。

### アーキテクチャ

```
PrometheusRule
  (PodOOMKilled / PodCrashLoopBackOff)
       ↓
  AlertManager (remediation ラベルでルーティング)
       ├─→ argo-events-oom      → EventSource (:12000/oomkilled)
       └─→ argo-events-crashloop → EventSource (:12000/crashloop)
                ↓ EventBus (NATS)
           Sensor (OOMKilled / CrashLoop)
                ↓ Workflow submit
    ┌──────────────────────────────────────┐
    │ OOMKilled WorkflowTemplate           │
    │  1. Pod → RS → Deployment 特定       │
    │  2. メモリリミット 1.5 倍にパッチ      │
    │  3. Grafana アノテーション通知         │
    └──────────────────────────────────────┘
    ┌──────────────────────────────────────┐
    │ CrashLoopBackOff WorkflowTemplate    │
    │  1. Pod ログ収集 (--previous)         │
    │  2. エラーパターン分類 (正規表現)       │
    │  3. Grafana アノテーション記録         │
    └──────────────────────────────────────┘
```

### 自動修復シナリオ

| トリガー | 実行アクション |
|---------|--------------|
| Pod OOMKilled | Deployment のメモリリミットを 1.5 倍に自動増加 |
| Pod CrashLoopBackOff (2分継続) | ログ収集 + エラーパターン分析 → Grafana に記録 |

### デプロイ手順

#### 1. Argo Workflows / Argo Events をインストール

```bash
# Argo Workflows (argo namespace に作成)
kubectl apply -f k8s/argocd/apps/argo-workflows.yaml

# Argo Events (argo-events namespace に作成)
kubectl apply -f k8s/argocd/apps/argo-events.yaml

# Pod が Ready になるまで待機
kubectl get pods -n argo -w
kubectl get pods -n argo-events -w
```

#### 2. remediation-runner イメージをビルド・push

```bash
# kaniko Job でビルド
kubectl apply -f k8s/aiops/auto-remediation/kaniko-job.yaml
kubectl logs -f job/build-remediation-runner -n aiops
```

#### 3. auto-remediation リソースをデプロイ (ArgoCD)

```bash
# aiops.yaml を適用 (aiops-auto-remediation / aiops-auto-remediation-events アプリが追加)
kubectl apply -f k8s/argocd/apps/aiops.yaml

# RBAC + WorkflowTemplates が aiops namespace に作成されることを確認
kubectl get workflowtemplate -n aiops

# EventBus/EventSource/Sensor が argo-events namespace に作成されることを確認
kubectl get eventbus,eventsource,sensor -n argo-events
```

#### 4. monitoring app を再 Sync (AlertManager 設定を反映)

```bash
# ArgoCD UI で monitoring app を Sync
# または
kubectl apply -f k8s/argocd/apps/monitoring.yaml
```

#### 5. 動作確認

```bash
# WorkflowTemplate の確認
kubectl get workflowtemplate -n aiops

# EventSource が Listen しているか確認
kubectl get svc -n argo-events | grep eventsource

# テスト: OOMKilled ワークフローを手動トリガー
kubectl create -n aiops -f - << 'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: test-oomkilled-
spec:
  workflowTemplateRef:
    name: remediate-oomkilled
  arguments:
    parameters:
      - name: namespace
        value: "default"
      - name: pod
        value: "test-pod"
      - name: container
        value: "test-container"
EOF

# Workflow 実行状況の確認
kubectl get workflows -n aiops
kubectl logs -n aiops -l workflows.argoproj.io/workflow --tail=50

# Argo Workflows UI
# http://argo-workflows.homelab.local
```

### Argo Workflows UI アクセス

| URL | 説明 |
|---|---|
| `http://argo-workflows.homelab.local` | Argo Workflows UI (認証不要) |

hosts ファイルへの追記:
```powershell
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.24  argo-workflows.homelab.local"
```

### ファイル構成

```
auto-remediation/
├── rbac.yaml                           # ServiceAccount / ClusterRole / RoleBinding
├── kaniko-job.yaml                     # remediation-runner イメージビルド
├── runner/                             # Python イメージ (kubernetes パッケージ)
│   ├── Dockerfile
│   └── requirements.txt
├── argo-events/
│   ├── eventbus.yaml                   # NATS native EventBus
│   ├── event-source.yaml               # AlertManager webhook 受信 (:12000)
│   ├── sensor-oomkilled.yaml           # OOMKilled → Workflow 起動
│   └── sensor-crashloop.yaml           # CrashLoop → Workflow 起動
└── argo-workflows/
    ├── workflow-oomkilled.yaml          # OOMKilled 修復 WorkflowTemplate
    └── workflow-crashloop.yaml          # CrashLoop 分析 WorkflowTemplate
```
