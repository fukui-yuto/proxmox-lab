# Argo Events 詳細ガイド — Kubernetes ネイティブのイベント駆動フレームワーク

## このツールが解決する問題

「何かが起きたら、自動で何かを実行したい」:

- Prometheus アラートが発火したら → 自動修復ワークフローを起動
- Webhook を受信したら → デプロイパイプラインを開始
- 定期的に (Cron) → データ収集バッチを実行

これを手動で作ると「ポーリングスクリプト + cron + Webhook サーバー」と
ツギハギだらけになる。

| 問題 | 内容 |
|------|------|
| イベントソースの多様性 | Webhook, メッセージキュー, Cron, ファイル変更... 全部対応したい |
| フィルタリング | 特定の条件のイベントだけ反応したい |
| トリガー先の多様性 | Argo Workflow, k8s リソース作成, HTTP 呼び出し... |
| 信頼性 | イベントを取りこぼさない仕組みが必要 |

Argo Events は **イベントソース → フィルタ → トリガー** のパイプラインを
Kubernetes リソースとして宣言的に定義できる。

---

## 核心コンセプト

```
┌─────────────┐      ┌─────────────┐      ┌─────────────────┐
│ EventSource │ ───→ │   Sensor    │ ───→ │    Trigger      │
│ (イベント発生源) │      │ (条件判定)    │      │ (アクション実行)   │
└─────────────┘      └─────────────┘      └─────────────────┘

例:
  Webhook受信  ───→  statusが"firing" ───→  Argo Workflow起動
  Cron (毎時) ───→  常にtrue          ───→  バッチJob作成
  Kafka消費   ───→  特定topic         ───→  HTTP POST
```

| 概念 | 役割 | 例え |
|------|------|------|
| **EventSource** | イベントの入り口。外部からの信号を受け取る | 「郵便受け」 |
| **Sensor** | イベントを監視し、条件に合ったら Trigger を発火 | 「センサー付きライト」 |
| **Trigger** | 実際のアクションを実行する | 「ライトが点灯する」 |

---

## アーキテクチャ

```
┌──────────────────────────────────────────────────────────┐
│  Kubernetes クラスター                                     │
│                                                          │
│  ┌────────────────────┐                                  │
│  │ EventBus (NATS)    │  ← イベントの中継バス              │
│  │ (メッセージキュー)    │                                  │
│  └──────┬─────────────┘                                  │
│         │                                                │
│  ┌──────┴──────────┐        ┌──────────────────────┐     │
│  │ EventSource Pod │        │ Sensor Pod           │     │
│  │                 │        │                      │     │
│  │ - Webhook 受信   │ ──→   │ - 条件チェック         │     │
│  │ - Cron 発火      │ EventBus│ - 条件合致 → Trigger │     │
│  │ - Kafka 消費     │        │                      │     │
│  └─────────────────┘        └──────────┬───────────┘     │
│                                        │                 │
│                                        ↓                 │
│                              ┌──────────────────┐        │
│                              │ Trigger 実行      │        │
│                              │ - Argo Workflow   │        │
│                              │ - k8s Resource    │        │
│                              │ - HTTP Request    │        │
│                              └──────────────────┘        │
└──────────────────────────────────────────────────────────┘
```

| コンポーネント | 役割 |
|--------------|------|
| **Controller** | EventSource と Sensor のリソースを監視し、対応する Pod を管理 |
| **EventSource Pod** | 実際にイベントを待ち受ける Pod (Webhook サーバーなど) |
| **Sensor Pod** | EventBus からイベントを受信し、条件判定して Trigger を発火 |
| **EventBus** | EventSource → Sensor 間のメッセージ中継 (デフォルトは NATS) |

---

## ファイル構成と解説

### `values.yaml` — Argo Events の Helm 設定

```yaml
# Argo Events — homelab 向け最小構成
# chart: argo-events (https://argoproj.github.io/argo-helm)

controller:
  resources:
    requests:
      cpu: 50m         # Controller: EventSource/Sensor リソースの監視・Pod管理
      memory: 128Mi
    limits:
      cpu: 200m
      memory: 256Mi
```

**controller** = EventSource や Sensor の CRD を監視して、必要な Pod を起動・管理する。
Argo Events の頭脳。

```yaml
eventsource:
  resources:
    requests:
      cpu: 50m         # EventSource Pod のデフォルトリソース
      memory: 64Mi
    limits:
      cpu: 100m
      memory: 128Mi
```

**eventsource** = イベントを受信する Pod のリソース制限。
Webhook を待ち受けたり、Cron で定期的にイベントを発生させる。

```yaml
sensor:
  resources:
    requests:
      cpu: 50m         # Sensor Pod のデフォルトリソース
      memory: 64Mi
    limits:
      cpu: 100m
      memory: 128Mi
```

**sensor** = イベントを受け取って条件判定し、Trigger を実行する Pod のリソース制限。

---

## このラボでの使い方

Argo Events は **aiops (自動修復) のイベント駆動部分** を担当:

```
Prometheus Alertmanager
  → Webhook で Argo Events の EventSource に通知
  → Sensor がアラート内容を判定
  → 条件に合致したら Argo Workflow (自動修復) をトリガー

例: "PodCrashLoopBackOff" アラート
  → EventSource (Webhook) が受信
  → Sensor が "severity=critical" をチェック
  → Trigger: 自動修復 Workflow を起動 (Pod 再起動)
```

---

## EventSource の書き方 (例)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: EventSource
metadata:
  name: alertmanager-webhook
  namespace: argo-events
spec:
  webhook:
    alertmanager:                    # このイベントソースの名前
      port: "12000"                  # Webhook を待ち受けるポート
      endpoint: "/alertmanager"      # URL パス
      method: POST                   # HTTP メソッド
```

これで `http://alertmanager-webhook:12000/alertmanager` に
POST リクエストが来たらイベントが発生する。

---

## Sensor の書き方 (例)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Sensor
metadata:
  name: auto-remediation
  namespace: argo-events
spec:
  dependencies:                      # 監視するイベント
    - name: alertmanager-event
      eventSourceName: alertmanager-webhook    # 上の EventSource
      eventName: alertmanager                  # イベント名

  triggers:                          # イベント受信時に実行するアクション
    - template:
        name: remediation-workflow
        argoWorkflow:                # Argo Workflow をトリガー
          operation: submit
          source:
            resource:                # 起動する Workflow の定義
              apiVersion: argoproj.io/v1alpha1
              kind: Workflow
              metadata:
                generateName: auto-remediation-
              spec:
                entrypoint: remediate
                # ... (Workflow の中身)
```

---

## EventSource の種類

| 種類 | 用途 | 例 |
|------|------|-----|
| **webhook** | HTTP リクエストを受信 | Alertmanager, GitHub Webhook |
| **calendar** | Cron スケジュール | 毎時・毎日のバッチ |
| **kafka** | Kafka メッセージ消費 | ストリーミングデータ処理 |
| **sns/sqs** | AWS イベント | クラウド連携 |
| **file** | ファイル変更検知 | 設定ファイル更新時 |
| **resource** | k8s リソース変更検知 | Pod 作成/削除時 |

---

## Argo Events vs 他のツール

| ツール | 特徴 | 適する場面 |
|--------|------|-----------|
| **Argo Events** | k8s ネイティブ、宣言的、Argo Workflows と統合 | k8s 内のイベント駆動自動化 |
| **AWS EventBridge** | AWS 統合 | AWS 環境 |
| **Zapier / IFTTT** | ノーコード | 簡単な SaaS 連携 |
| **カスタム Webhook サーバー** | 自由度高い | 特殊要件 |

---

## Argo Workflows との関係

```
Argo Events: 「いつ」「何をきっかけに」実行するかを決める (トリガー)
Argo Workflows: 「何を」「どの順番で」実行するかを決める (実行エンジン)

Events が「発火スイッチ」、Workflows が「実行される処理」
```

この2つを組み合わせることで、完全に宣言的なイベント駆動自動化が実現できる。
