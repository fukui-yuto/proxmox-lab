# AIOps 実施計画

既存の監視・ログスタックを活用して IT 運用を AI で知能化するロードマップ。

---

## ディレクトリ構成 (最終形)

```
k8s/aiops/
├── PLAN.md                        # このファイル (タスク管理)
├── README.md                      # 手順書 (実装時に追記)
├── step1-alerting/                # Step1: Grafana アラート知能化
│   ├── prometheusrule.yaml        # PromQL ルール定義
│   └── alertmanager-config.yaml   # グループ化・抑制ルール
├── step2-log-anomaly/             # Step2: ログ異常検知
│   ├── cronjob.yaml               # k8s CronJob
│   ├── pushgateway/               # Prometheus Pushgateway
│   │   └── values.yaml
│   └── detector/                  # Python 異常検知スクリプト
│       ├── Dockerfile
│       ├── requirements.txt
│       └── detect.py
├── step3-llm-summary/             # Step3: LLM アラートサマリ
│   ├── deployment.yaml            # alert-summarizer Pod
│   ├── secret.yaml                # API キー (Vault 管理)
│   └── summarizer/
│       ├── Dockerfile
│       ├── requirements.txt
│       └── app.py
└── step4-auto-remediation/        # Step4: 自動修復 Runbook
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

- [ ] `predict_linear()` でディスク容量枯渇予測アラートを追加
- [ ] `rate()` + `increase()` で CPU スパイクトレンド検知ルール追加
- [ ] AlertManager の `group_by` でアラートグループ化設定
- [ ] AlertManager の `inhibit_rules` でノイズ抑制設定
- [ ] `step1-alerting/prometheusrule.yaml` に定義をコード化
- [ ] `step1-alerting/alertmanager-config.yaml` に設定をコード化
- [ ] `k8s/monitoring/values.yaml` に組み込み
- [ ] README.md に手順を記載
- [ ] git commit && git push

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

- [ ] Prometheus Pushgateway を Helm でインストール
  - `step2-log-anomaly/pushgateway/values.yaml` 作成
  - ArgoCD App 追加
- [ ] Python 異常検知スクリプト実装
  - `detect.py`: ES からログ件数を時系列取得 → ADTK で異常スコア計算
  - `requirements.txt`: `elasticsearch`, `adtk`, `prometheus_client`
  - `Dockerfile` 作成
- [ ] Harbor にイメージを push
- [ ] k8s CronJob マニフェスト作成 (`cronjob.yaml`)
  - 5分ごとに実行
  - Vault から ES 認証情報を取得
- [ ] Grafana に異常スコアのパネルを追加
- [ ] README.md に手順を記載
- [ ] git commit && git push

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

- [ ] Vault に Claude API キーを登録
- [ ] `app.py` 実装 (FastAPI)
  - AlertManager webhook 受信エンドポイント
  - ES から直近エラーログを取得
  - Claude API でサマリ生成 (「何が起きているか」「次に確認すべきこと」)
  - Slack webhook で通知 (or Grafana Annotation API)
- [ ] `Dockerfile` / `requirements.txt` 作成
- [ ] Harbor にイメージを push
- [ ] k8s Deployment / Service マニフェスト作成
- [ ] AlertManager の webhook receiver 設定に追加
- [ ] README.md に手順を記載
- [ ] git commit && git push

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

- [ ] Argo Workflows インストール
  - ArgoCD App 追加
- [ ] Argo Events インストール
  - AlertManager → Argo Events EventSource 設定
- [ ] OOMKilled 自動修復 Workflow 作成
- [ ] CrashLoopBackOff 分析 Workflow 作成 (Claude API 連携)
- [ ] README.md に手順を記載
- [ ] git commit && git push

### 学べること
- Argo Events / Argo Workflows の設計
- k8s イベント駆動アーキテクチャ
- 自動修復 Runbook の考え方

---

## 進捗サマリ

| Step | 内容 | 状態 |
|------|------|------|
| Step 1 | Grafana アラート知能化 | 未着手 |
| Step 2 | ログ異常検知 CronJob | 未着手 |
| Step 3 | LLM アラートサマリ | 未着手 |
| Step 4 | 自動修復 Runbook | 未着手 |

---

## 前提条件

- [ ] クラスター起動 + 各 ArgoCD App が正常 Sync 済み
- [ ] monitoring (Prometheus / Grafana) 稼働中
- [ ] logging (Elasticsearch / Fluent-bit / Kibana) 稼働中
- [ ] Vault 起動・Unseal 済み
