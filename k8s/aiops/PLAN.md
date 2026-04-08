# AIOps 実施計画

既存の監視・ログスタックを活用して IT 運用を AI で知能化するロードマップ。

---

## ディレクトリ構成 (最終形)

```
k8s/aiops/
├── PLAN.md                          # このファイル (タスク管理)
├── README.md                        # 手順書
├── alerting/                        # 予測・トレンド型アラートルール
│   ├── prometheusrule.yaml          # PromQL ルール定義
│   └── alertmanager-config.yaml     # グループ化・抑制ルール (参照用)
├── anomaly-detection/               # ログ異常検知
│   ├── cronjob.yaml                 # k8s CronJob (5分ごと)
│   ├── pushgateway/                 # Prometheus Pushgateway
│   │   └── values.yaml
│   └── detector/                    # Python 異常検知スクリプト
│       ├── Dockerfile
│       ├── requirements.txt
│       └── detect.py
├── alert-summarizer/                # LLM アラートサマリ
│   ├── deployment.yaml              # alert-summarizer Pod
│   ├── secret.yaml                  # API キー (Vault 管理)
│   └── app/
│       ├── Dockerfile
│       ├── requirements.txt
│       └── app.py
└── auto-remediation/                # 自動修復 Runbook
    ├── argo-events/
    │   └── event-source.yaml
    └── argo-workflows/
        └── remediation-workflow.yaml
```

---

## 全体アーキテクチャ

```
既存スタック                       追加コンポーネント
─────────────────────────────────────────────────────────
Prometheus ──────────────────────→ [Step1] PrometheusRule / AlertManager 改善
                                         predict_linear() でディスク枯渇予測
                                         inhibit_rules でアラートノイズ削減

ELK (ES/Fluent-bit/Kibana) ─────→ [Step2] Python CronJob (異常検知)
                                         → Pushgateway → Grafana

AlertManager ────────────────────→ [Step3] alert-summarizer (Claude API)
                                         → Slack / Grafana Annotation

k8s Events / Prometheus ────────→ [Step4] Argo Events + Argo Workflows
                                         既知障害パターンを自動修復
```

---

## Step 1: Grafana アラート知能化

**目的:** 閾値アラートを「予測・傾向検知」に昇格させる
**新規コンポーネント:** なし (既存 Prometheus + Grafana のみ)
**難易度:** ★☆☆☆☆

### タスク

- [x] `predict_linear()` でディスク容量枯渇予測アラートを追加
- [x] `rate()` + `increase()` で CPU スパイクトレンド検知ルール追加
- [x] AlertManager の `group_by` でアラートグループ化設定
- [x] AlertManager の `inhibit_rules` でノイズ抑制設定
- [x] `alerting/prometheusrule.yaml` に定義をコード化
- [x] `alerting/alertmanager-config.yaml` に設定をコード化
- [x] `k8s/monitoring/values.yaml` に組み込み
- [x] README.md に手順を記載
- [x] git commit && git push

### 学べること
- PromQL の応用 (predict_linear, rate, increase)
- アラート設計のベストプラクティス
- AlertManager の Group / Inhibit / Route 設計

---

## Step 2: ログ異常検知 CronJob

**目的:** Elasticsearch のログから ML で異常パターンを自動検出
**新規コンポーネント:** Prometheus Pushgateway, Python CronJob (自作)
**難易度:** ★★★☆☆

### アーキテクチャ

```
Fluent-bit → Elasticsearch
                  ↓ ES Query API
          [Python CronJob (k8s)] ← ADTK / Isolation Forest
          - ログ件数の時系列異常検知
          - エラーレートの急増検知
                  ↓ prometheus_client
          Prometheus Pushgateway → Grafana ダッシュボード
```

### タスク

- [x] Prometheus Pushgateway を Helm でインストール
  - `anomaly-detection/pushgateway/values.yaml` 作成
  - ArgoCD App 追加 (`aiops-pushgateway`)
- [x] Python 異常検知スクリプト実装
  - `anomaly-detection/detector/detect.py`: ES からログ件数を時系列取得 → ADTK で異常スコア計算
  - `anomaly-detection/detector/requirements.txt`: `elasticsearch`, `adtk`, `prometheus_client`
  - `anomaly-detection/detector/Dockerfile` 作成
- [x] kaniko Job でイメージをビルド・Harbor に push (`anomaly-detection/kaniko-job.yaml`)
- [x] k8s CronJob マニフェスト作成 (`anomaly-detection/cronjob.yaml`)
  - 5分ごとに実行 / ES 認証なし (現状)
- [ ] Grafana に異常スコアのパネルを追加
- [x] README.md に手順を記載
- [x] git commit && git push

### 学べること
- 時系列異常検知アルゴリズム (ADTK, Isolation Forest)
- Elasticsearch Python クライアント
- Prometheus Pushgateway パターン
- k8s CronJob の設計

---

## Step 3: LLM によるアラートサマリ

**目的:** AlertManager webhook → Claude API でアラートを自然言語サマリ化して通知
**新規コンポーネント:** alert-summarizer Pod (Python FastAPI)
**難易度:** ★★★☆☆

### アーキテクチャ

```
AlertManager
    ↓ webhook (HTTP POST)
[alert-summarizer Pod]
    ├─ AlertManager からアラート受信
    ├─ Elasticsearch から直近ログを取得
    └─ Claude API にコンテキストを渡してサマリ生成
         ↓
    Slack 通知 / Grafana Annotation 追加
```

### タスク

- [x] Vault に Claude API キーを登録 → k8s Secret で代替 (`alert-summarizer-secret`)
- [x] `alert-summarizer/app/app.py` 実装 (FastAPI)
  - AlertManager webhook 受信エンドポイント
  - ES から直近エラーログを取得
  - Claude API でサマリ生成 (「何が起きているか」「次に確認すべきこと」)
  - Grafana Annotation API で記録 / Slack webhook で通知 (オプション)
- [x] `alert-summarizer/app/Dockerfile` / `requirements.txt` 作成
- [x] Harbor にイメージを push (kaniko-job.yaml)
- [x] `alert-summarizer/deployment.yaml` k8s Deployment / Service マニフェスト作成
- [x] AlertManager の webhook receiver 設定に追加 (`k8s/monitoring/values.yaml`)
- [x] README.md に手順を記載
- [x] git commit && git push

### 学べること
- LLM API (Claude) の活用
- AlertManager webhook の仕組み
- FastAPI による軽量 API サーバ実装
- Vault からのシークレット動的取得

---

## Step 4: 自動修復 Runbook

**目的:** 既知の障害パターンを検知したら Argo Workflows で自動対処
**新規コンポーネント:** Argo Events, Argo Workflows
**難易度:** ★★★★☆

### 自動修復シナリオ (例)

| トリガー | アクション |
|---------|-----------|
| Pod が OOMKilled | memory limit を増やして再デプロイ + Slack 通知 |
| CrashLoopBackOff (3回以上) | ログを ES に保存 → Claude API で原因分析 → Slack 通知 |
| ノード CPU 95%超 (5分継続) | 非重要 Pod を別ノードに退避 |

### タスク

- [x] Argo Workflows インストール
  - `k8s/argo-workflows/values.yaml` + ArgoCD App 追加 (`k8s/argocd/apps/argo-workflows.yaml`)
- [x] Argo Events インストール
  - `k8s/argo-events/values.yaml` + ArgoCD App 追加 (`k8s/argocd/apps/argo-events.yaml`)
  - EventBus / EventSource / Sensor 設定 (`auto-remediation/argo-events/`)
- [x] OOMKilled 自動修復 Workflow 作成 (`auto-remediation/argo-workflows/workflow-oomkilled.yaml`)
  - Pod → ReplicaSet → Deployment を辿り、メモリリミットを 1.5 倍にパッチ
- [x] CrashLoopBackOff 分析 Workflow 作成 (`auto-remediation/argo-workflows/workflow-crashloop.yaml`)
  - ログ収集 + 正規表現エラーパターン分析 (Claude API 不使用)
- [x] PrometheusRule に PodOOMKilled / PodCrashLoopBackOff アラート追加
- [x] AlertManager に Argo Events webhook receiver 追加
- [x] remediation-runner イメージ用 Dockerfile + kaniko Job 作成
- [x] README.md に手順を記載
- [x] git commit && git push

### 学べること
- Argo Events / Argo Workflows の設計
- k8s イベント駆動アーキテクチャ
- 自動修復 Runbook の考え方

---

## 進捗サマリ

| Step | 内容 | 状態 |
|------|------|------|
| Step 1 | Grafana アラート知能化 | ✅ 完了 |
| Step 2 | ログ異常検知 CronJob | ✅ 完了 (Grafana パネルは未) |
| Step 3 | LLM アラートサマリ | ✅ 完了 |
| Step 4 | 自動修復 Runbook | ✅ 完了 |

---

## 前提条件

- [ ] クラスター起動 + 各 ArgoCD App が正常 Sync 済み
- [ ] monitoring (Prometheus / Grafana) 稼働中
- [ ] logging (Elasticsearch / Fluent-bit / Kibana) 稼働中
- [ ] Vault 起動・Unseal 済み
