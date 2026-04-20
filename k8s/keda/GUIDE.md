# KEDA ガイド

## 概要

KEDA (Kubernetes Event-Driven Autoscaling) は、イベントソースに基づいて Pod をゼロからスケールアウト/インできる Kubernetes オートスケーラー。
標準の HPA は CPU/メモリのみ対応だが、KEDA は Prometheus メトリクス・Kafka・Redis など多様なスケールトリガーに対応する。

### HPA との違い

| 機能 | HPA | KEDA |
|------|-----|------|
| トリガー | CPU / メモリのみ | 60+ のスケーラー |
| ゼロスケール | 不可 (min=1) | 可能 (min=0) |
| 外部イベント | 不可 | Kafka / SQS / Redis 等 |
| Prometheus 連携 | カスタムメトリクス要 | ネイティブ対応 |

---

## 主要リソース

### ScaledObject

Deployment / StatefulSet に対するスケール設定。

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: my-app-scaler
spec:
  scaleTargetRef:
    name: my-app
  minReplicaCount: 0
  maxReplicaCount: 10
  cooldownPeriod: 60
  triggers:
    - type: prometheus
      metadata:
        serverAddress: http://kube-prometheus-stack-prometheus.monitoring:9090
        metricName: http_requests_total
        threshold: "100"
        query: sum(rate(http_requests_total{job="my-app"}[1m]))
```

### ScaledJob

Job に対するスケール設定 (バッチ処理向け)。

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledJob
metadata:
  name: my-job-scaler
spec:
  jobTargetRef:
    template:
      spec:
        containers:
          - name: worker
            image: my-worker:latest
  triggers:
    - type: redis
      metadata:
        address: redis:6379
        listName: job-queue
        listLength: "5"
```

---

## スケーラー一覧 (homelab で使えるもの)

| スケーラー | 用途 |
|-----------|------|
| `prometheus` | Prometheus メトリクスでスケール |
| `cpu` | CPU 使用率 (HPA 互換) |
| `memory` | メモリ使用率 (HPA 互換) |
| `kafka` | Kafka コンシューマーラグ |
| `redis` | Redis リストの長さ |
| `cron` | 時刻ベースのスケール |

---

## aiops との統合例

aiops-auto-remediation と組み合わせると、アラート発生時に自動でワーカー数を増やす構成が可能。

```yaml
# Alertmanager がメトリクスを Pushgateway に送信
# → KEDA が Prometheus 経由でスケール判定
triggers:
  - type: prometheus
    metadata:
      serverAddress: http://kube-prometheus-stack-prometheus.monitoring:9090
      query: |
        count(ALERTS{alertname="HighErrorRate", alertstate="firing"})
      threshold: "1"
```

---

## 確認コマンド

```bash
# ScaledObject 一覧
kubectl get scaledobject -A

# ScaledJob 一覧
kubectl get scaledjob -A

# スケール状態の詳細
kubectl describe scaledobject <name> -n <namespace>
```

---

## ファイル構成と各ファイルのコード解説

### ファイル構成一覧

| ファイル | パス | 役割 |
|---------|------|------|
| `values.yaml` | `k8s/keda/values.yaml` | KEDA Helm chart のカスタム設定値。オペレーター・メトリクスサーバー・Webhook のリソース制限や Prometheus 監視を定義する |
| `README.md` | `k8s/keda/README.md` | セットアップ手順・使い方クイックリファレンス |
| `GUIDE.md` | `k8s/keda/GUIDE.md` | 本ファイル。KEDA の概念説明・学習用ドキュメント |
| `keda.yaml` | `k8s/argocd/apps/keda.yaml` | ArgoCD Application マニフェスト。ArgoCD が KEDA をデプロイ・同期するための定義 |

---

### values.yaml 全設定解説

`values.yaml` は Helm chart `kedacore/keda` に渡すカスタム値ファイル。KEDA のコンポーネント構成・リソース制限・監視設定をすべてここで管理する。

#### 1. CRD インストール設定

```yaml
crds:
  install: true
```

| キー | 値 | 説明 |
|------|-----|------|
| `crds.install` | `true` | KEDA が使用する CRD (Custom Resource Definition) を Helm chart のインストール時に自動作成する。`ScaledObject`、`ScaledJob`、`TriggerAuthentication` などのカスタムリソースを Kubernetes に登録するために必要。`false` にすると CRD を事前に手動インストールする必要がある。通常は `true` のままで問題ない |

> **初心者向け補足:** CRD とは Kubernetes に「新しい種類のリソース」を追加する仕組み。KEDA をインストールすると `ScaledObject` という新しいリソースタイプが使えるようになるが、それを可能にするのが CRD のインストール。

---

#### 2. Operator (オペレーター) 設定

```yaml
operator:
  replicaCount: 1
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 256Mi
```

KEDA Operator は KEDA の中核コンポーネント。`ScaledObject` や `ScaledJob` リソースを監視し、トリガー条件に応じて HPA の作成・更新やレプリカ数の変更を行う「コントローラー」。

| キー | 値 | 説明 |
|------|-----|------|
| `operator.replicaCount` | `1` | Operator Pod のレプリカ数。ホームラボ環境ではリソース節約のため 1 で十分。本番環境では HA (高可用性) のために 2 に増やすこともある |
| `operator.resources.requests.cpu` | `50m` | Pod スケジューリング時に確保される最低 CPU リソース。50m = 0.05 コア (50 ミリコア)。Kubernetes スケジューラーはこの値を基にノード配置を決定する |
| `operator.resources.requests.memory` | `128Mi` | Pod スケジューリング時に確保される最低メモリ。128MiB (約 134MB) |
| `operator.resources.limits.cpu` | `500m` | CPU の上限値。バースト時に最大 0.5 コアまで使用可能。これを超えるとスロットリング (速度制限) される |
| `operator.resources.limits.memory` | `256Mi` | メモリの上限値。これを超えると Pod は OOMKilled (Out of Memory で強制終了) される |

> **初心者向け補足:** `requests` は「最低これだけは確保してほしい」量、`limits` は「これ以上は使わせない」上限。requests が小さすぎるとノードのリソースが逼迫した時に性能劣化し、limits が小さすぎると Pod が頻繁に再起動する。ホームラボではリソースが限られるため控えめに設定している。

---

#### 3. Metrics Server (メトリクスサーバー) 設定

```yaml
metricsServer:
  replicaCount: 1
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      cpu: 200m
      memory: 128Mi
```

KEDA Metrics Server は Kubernetes の External Metrics API を実装するコンポーネント。HPA が KEDA 経由で外部メトリクス (Prometheus クエリの結果など) を取得するための橋渡し役。

| キー | 値 | 説明 |
|------|-----|------|
| `metricsServer.replicaCount` | `1` | Metrics Server Pod のレプリカ数。ホームラボでは 1 で十分 |
| `metricsServer.resources.requests.cpu` | `50m` | 最低確保 CPU。メトリクス取得は軽量な処理なので 50m で十分 |
| `metricsServer.resources.requests.memory` | `64Mi` | 最低確保メモリ。Operator より軽量なので 64MiB に抑えている |
| `metricsServer.resources.limits.cpu` | `200m` | CPU 上限。メトリクス API のリクエスト処理は軽いため 200m で十分 |
| `metricsServer.resources.limits.memory` | `128Mi` | メモリ上限。128MiB |

> **初心者向け補足:** HPA (Horizontal Pod Autoscaler) は通常 CPU/メモリしか見れないが、KEDA Metrics Server が「Prometheus のクエリ結果」を HPA が理解できる形式に変換して提供する。つまり HPA が「Prometheus からのカスタムメトリクス」でスケールできるようになる仕組み。

---

#### 4. Webhooks (Admission Webhook) 設定

```yaml
webhooks:
  enabled: true
  replicaCount: 1
  resources:
    requests:
      cpu: 20m
      memory: 64Mi
    limits:
      cpu: 200m
      memory: 128Mi
```

KEDA Webhooks は Kubernetes の Admission Webhook として動作し、`ScaledObject` などのリソースが作成・更新される際にバリデーション (入力値の検証) を行うコンポーネント。

| キー | 値 | 説明 |
|------|-----|------|
| `webhooks.enabled` | `true` | Webhook コンポーネントを有効化する。`true` にすると不正な ScaledObject の作成をリアルタイムで防げる |
| `webhooks.replicaCount` | `1` | Webhook Pod のレプリカ数 |
| `webhooks.resources.requests.cpu` | `20m` | 最低確保 CPU。Webhook はリソース作成時のみ呼ばれるため非常に軽量で 20m で十分 |
| `webhooks.resources.requests.memory` | `64Mi` | 最低確保メモリ |
| `webhooks.resources.limits.cpu` | `200m` | CPU 上限 |
| `webhooks.resources.limits.memory` | `128Mi` | メモリ上限 |

> **初心者向け補足:** Admission Webhook とは「Kubernetes API サーバーにリソースが作成/更新される前に横取りして検証するフック」。例えば `minReplicaCount` に負の数を設定した ScaledObject を作ろうとすると、Webhook がリジェクト (拒否) してくれる。

---

#### 5. Prometheus 監視設定

```yaml
prometheus:
  metricServer:
    enabled: true
    serviceMonitor:
      enabled: true
  operator:
    enabled: true
    serviceMonitor:
      enabled: true
  webhooks:
    enabled: true
    serviceMonitor:
      enabled: true
```

この設定は KEDA の各コンポーネント自身のメトリクスを Prometheus で収集するための設定。KEDA がスケールした回数やエラー数などを Grafana で可視化できるようになる。

| キー | 値 | 説明 |
|------|-----|------|
| `prometheus.metricServer.enabled` | `true` | Metrics Server が `/metrics` エンドポイントでメトリクスを公開する |
| `prometheus.metricServer.serviceMonitor.enabled` | `true` | Metrics Server 用の ServiceMonitor リソースを作成する。Prometheus Operator がこの ServiceMonitor を検出し、自動的にスクレイプ対象に追加する |
| `prometheus.operator.enabled` | `true` | Operator が `/metrics` エンドポイントでメトリクスを公開する |
| `prometheus.operator.serviceMonitor.enabled` | `true` | Operator 用の ServiceMonitor を作成する。スケール実行回数・エラー数・キュー長などの運用メトリクスが取得可能になる |
| `prometheus.webhooks.enabled` | `true` | Webhooks が `/metrics` エンドポイントでメトリクスを公開する |
| `prometheus.webhooks.serviceMonitor.enabled` | `true` | Webhooks 用の ServiceMonitor を作成する。Webhook の呼び出し回数・レイテンシなどを監視できる |

> **初心者向け補足:** ServiceMonitor は Prometheus Operator が提供する CRD で、「どのサービスのメトリクスを収集するか」を宣言的に定義するもの。ServiceMonitor を作成すると Prometheus が自動でそのサービスのメトリクスを定期収集し始める。これにより KEDA 自体の健全性も Grafana ダッシュボードで確認できるようになる。

---

#### コンポーネント間の関係まとめ

```
┌─────────────────────────────────────────────────────────────┐
│  Kubernetes API Server                                       │
│                                                             │
│  ① ScaledObject 作成 → Webhook がバリデーション             │
│  ② Operator が ScaledObject を監視                          │
│  ③ Operator がトリガー条件を評価 (Prometheus 等へクエリ)     │
│  ④ 条件一致 → HPA を作成/更新 → Pod スケール               │
│  ⑤ HPA が Metrics Server 経由で外部メトリクスを取得         │
│                                                             │
│  Prometheus ← ServiceMonitor で各コンポーネントを監視        │
└─────────────────────────────────────────────────────────────┘
```

| コンポーネント | 役割 | リソース消費の傾向 |
|--------------|------|------------------|
| Operator | ScaledObject の監視・HPA 管理 | 中 (常時動作するコントローラーループ) |
| Metrics Server | 外部メトリクス API の提供 | 低〜中 (HPA のポーリング間隔で呼ばれる) |
| Webhooks | リソース作成時のバリデーション | 低 (リソース作成/更新時のみ動作) |
