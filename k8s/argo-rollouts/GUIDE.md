# Argo Rollouts ガイド

## 概要

Argo Rollouts は Kubernetes のプログレッシブデリバリー (段階的リリース) コントローラー。
ArgoCD と統合して **カナリアデプロイ** や **Blue-Green デプロイ** を実現する。

### 標準 Deployment との違い

| 機能 | Deployment | Rollout |
|------|-----------|---------|
| デプロイ戦略 | RollingUpdate / Recreate のみ | Canary / Blue-Green |
| トラフィック制御 | 不可 | weight ベースで段階的に移行 |
| 自動昇格 / ロールバック | なし | metrics 判定で自動化可能 |
| ArgoCD 統合 | 標準 | Rollout リソースとして可視化 |

---

## デプロイ戦略

### Canary (カナリア)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: my-app
spec:
  strategy:
    canary:
      steps:
        - setWeight: 10    # 10% のトラフィックを新バージョンへ
        - pause: {}        # 手動承認待ち
        - setWeight: 50
        - pause: {duration: 60s}
        - setWeight: 100
```

### Blue-Green

```yaml
spec:
  strategy:
    blueGreen:
      activeService: my-app-active
      previewService: my-app-preview
      autoPromotionEnabled: false  # 手動昇格
```

---

## Analysis (自動判定)

Prometheus メトリクスで自動ロールバック/昇格を判定できる。

```yaml
spec:
  strategy:
    canary:
      analysis:
        templates:
          - templateName: success-rate
        startingStep: 2
        args:
          - name: service-name
            value: my-app-canary
---
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: success-rate
spec:
  metrics:
    - name: success-rate
      interval: 30s
      failureLimit: 3
      provider:
        prometheus:
          address: http://kube-prometheus-stack-prometheus.monitoring:9090
          query: |
            sum(rate(http_requests_total{job="{{args.service-name}}",status!~"5.."}[2m]))
            /
            sum(rate(http_requests_total{job="{{args.service-name}}"}[2m]))
      successCondition: result[0] >= 0.95
```

---

## kubectl プラグイン

```bash
# インストール
curl -LO https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64
chmod +x kubectl-argo-rollouts-linux-amd64 && mv it /usr/local/bin/kubectl-argo-rollouts

# Rollout 一覧
kubectl argo rollouts list rollouts -n <namespace>

# 状態確認
kubectl argo rollouts get rollout <name> -n <namespace> --watch

# 手動昇格
kubectl argo rollouts promote <name> -n <namespace>

# ロールバック
kubectl argo rollouts undo <name> -n <namespace>
```

---

## ArgoCD との統合

ArgoCD の Application で `Rollout` リソースを管理すると、ArgoCD UI 上で Rollout の進行状況が可視化される。
`argocd-rollouts` namespace の `argo-rollouts-controller` が Rollout リソースを監視し、トラフィック切り替えを制御する。

---

## ファイル構成と各ファイルのコード解説

### ファイル構成一覧

| ファイルパス | 役割 | 説明 |
|-------------|------|------|
| `k8s/argo-rollouts/values.yaml` | Helm values | Argo Rollouts チャートに渡すカスタム設定値。コントローラー・ダッシュボードのリソースやメトリクス設定を定義 |
| `k8s/argo-rollouts/README.md` | 運用手順書 | セットアップ手順、操作コマンド、ファイル構成の概要 |
| `k8s/argo-rollouts/GUIDE.md` | 概念説明 (本ファイル) | Argo Rollouts の概念・戦略・使い方の学習用ドキュメント |
| `k8s/argocd/apps/argo-rollouts.yaml` | ArgoCD Application | ArgoCD がこのアプリを GitOps で管理するための定義。Helm chart のソースと同期ポリシーを記述 |

---

### values.yaml の全設定解説

`values.yaml` は Helm chart `argoproj/argo-rollouts` (v2.38.0) に渡すカスタム設定ファイル。
Helm chart にはデフォルト値が存在するが、このファイルで上書きしたい項目だけを記述する。

```yaml
## Argo Rollouts Helm values
## Chart: argoproj/argo-rollouts

installCRDs: true

controller:
  replicas: 1
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 256Mi
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true

dashboard:
  enabled: true
  replicas: 1
  ingress:
    enabled: true
    ingressClassName: traefik
    hosts:
      - argo-rollouts.homelab.local
    paths:
      - /
  resources:
    requests:
      cpu: 20m
      memory: 64Mi
    limits:
      cpu: 200m
      memory: 128Mi
```

以下、各セクションを詳しく解説する。

---

#### `installCRDs: true` — CRD の自動インストール

```yaml
installCRDs: true
```

**CRD (Custom Resource Definition) とは:**
Kubernetes に新しいリソースタイプを追加する仕組み。Argo Rollouts では `Rollout`、`AnalysisTemplate`、`AnalysisRun`、`Experiment` などのカスタムリソースを使うため、これらの CRD を事前にクラスターに登録する必要がある。

**この設定の意味:**
- `true` に設定すると、Helm chart のインストール時に CRD も自動的にインストールされる
- `false` にすると CRD は手動でインストールする必要がある
- ホームラボでは管理を簡単にするため `true` を推奨

**注意点:**
Helm は CRD のアップグレード (バージョンアップ時の更新) を自動では行わない。chart のバージョンを上げた際に CRD の変更がある場合は、手動で `kubectl apply -f` する必要がある場合がある。ただし ArgoCD の `ServerSideApply=true` オプションにより、多くの場合は自動で差分が適用される。

---

#### `controller.replicas: 1` — コントローラーのレプリカ数

```yaml
controller:
  replicas: 1
```

**コントローラーとは:**
Argo Rollouts のコア。`Rollout` リソースを監視し、カナリアや Blue-Green のトラフィック切り替えロジックを実行するプロセス。

**レプリカ数の考え方:**
- `1`: 単一インスタンス。ホームラボではリソース節約のためこれで十分
- `2` 以上: 高可用性 (HA) 構成。本番環境ではコントローラーがダウンすると Rollout が進行しなくなるため、2〜3 レプリカが推奨される
- Argo Rollouts コントローラーはリーダー選出 (leader election) を使うため、複数レプリカでも実際に動作するのは 1 つだけ。他はスタンバイとして待機する

**ホームラボでの判断:**
リソースが限られているため `1` で運用。コントローラーが落ちても Rollout 中のアプリのトラフィックには影響しない (既に適用済みの Service/Ingress 設定は維持される)。コントローラー復帰後に Rollout が再開する。

---

#### `controller.resources` — コントローラーのリソース制限

```yaml
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 256Mi
```

**Kubernetes のリソース管理の基本:**

| 項目 | 意味 | 超過時の動作 |
|------|------|-------------|
| `requests.cpu` | スケジューリング時に確保される最低 CPU | ノード配置の判断に使用 |
| `requests.memory` | スケジューリング時に確保される最低メモリ | ノード配置の判断に使用 |
| `limits.cpu` | 使用できる CPU の上限 | スロットリング (速度制限) される |
| `limits.memory` | 使用できるメモリの上限 | OOMKill (強制終了) される |

**各値の解説:**
- `cpu: 50m` (requests): 50 ミリコア = 0.05 CPU コア。コントローラーは普段アイドルに近いため少量で十分
- `memory: 128Mi` (requests): 128 MiB。起動時のベースラインメモリ
- `cpu: 500m` (limits): Rollout 処理中のバースト対応。多数の Rollout を同時処理する場合に使われる
- `memory: 256Mi` (limits): 多数の Rollout/AnalysisRun オブジェクトをキャッシュしても余裕がある値

**ホームラボでの考慮:**
pve-node02 のワーカー (4GB RAM) で動作するため、requests は控えめに設定。limits は安全弁として設定しつつ、実運用では requests 付近で安定する。

---

#### `controller.metrics` — Prometheus メトリクス連携

```yaml
  metrics:
    enabled: true
    serviceMonitor:
      enabled: true
```

**メトリクスとは:**
Argo Rollouts コントローラーが公開するパフォーマンス・運用指標。例:
- `rollout_info`: 現在の Rollout の状態 (Healthy, Progressing, Degraded 等)
- `rollout_phase`: 各 Rollout のフェーズ
- `analysis_run_metric_phase`: AnalysisRun の結果
- `controller_clientset_k8s_request_total`: API サーバーへのリクエスト数

**`enabled: true` の意味:**
コントローラー Pod にメトリクスエンドポイント (`/metrics`) を公開する。これにより Prometheus がスクレイピングできるようになる。

**`serviceMonitor.enabled: true` の意味:**
Prometheus Operator の `ServiceMonitor` リソースを自動作成する。

ServiceMonitor は「Prometheus にこのサービスのメトリクスを収集してね」と宣言するリソース。これがないと Prometheus は Argo Rollouts のメトリクスを自動検出できない。

**連携の流れ:**
1. Argo Rollouts コントローラーが `:8090/metrics` でメトリクスを公開
2. ServiceMonitor が作成され、Prometheus Operator がそれを検出
3. Prometheus が自動的にスクレイピング対象に追加
4. Grafana で Rollout のダッシュボードを表示可能に

**本ラボでの活用:**
kube-prometheus-stack (monitoring namespace) で Prometheus が稼働しており、ServiceMonitor を検出して自動収集する。Rollout の成功率やデプロイ時間を Grafana で可視化できる。

---

#### `dashboard` — Argo Rollouts Dashboard

```yaml
dashboard:
  enabled: true
  replicas: 1
```

**ダッシュボードとは:**
Argo Rollouts 専用の Web UI。Rollout の進行状況をリアルタイムで視覚的に確認できる。

**できること:**
- 全 Rollout のリスト表示と状態確認
- カナリアの weight 進行状況の可視化
- AnalysisRun の結果表示
- 手動での Promote (昇格) / Abort (中断) 操作

**`replicas: 1`:**
ダッシュボードは読み取り専用の UI であり、ステートレスなので 1 レプリカで十分。

---

#### `dashboard.ingress` — Traefik Ingress 設定

```yaml
  ingress:
    enabled: true
    ingressClassName: traefik
    hosts:
      - argo-rollouts.homelab.local
    paths:
      - /
```

**Ingress とは:**
クラスター外部から内部の Service にアクセスするための HTTP(S) ルーティングルール。

**各設定の意味:**

| 設定 | 値 | 説明 |
|------|-----|------|
| `enabled` | `true` | Ingress リソースを作成する |
| `ingressClassName` | `traefik` | k3s デフォルトの Traefik Ingress Controller を使用 |
| `hosts` | `argo-rollouts.homelab.local` | このホスト名でアクセスした場合にルーティング |
| `paths` | `/` | 全パスをダッシュボードに転送 |

**アクセスの流れ:**
1. Windows の hosts ファイルに `192.168.210.25 argo-rollouts.homelab.local` を追記
2. ブラウザで `http://argo-rollouts.homelab.local` にアクセス
3. DNS 解決で 192.168.210.25 (k3s-worker04) へ到達
4. Traefik が `Host: argo-rollouts.homelab.local` ヘッダーを見て Argo Rollouts Dashboard Service にルーティング
5. Dashboard の Pod が応答を返す

**`ingressClassName: traefik` について:**
k3s には Traefik が Ingress Controller としてプリインストールされている。`ingressClassName` を指定することで、複数の Ingress Controller がある環境でもどれを使うか明示できる。

---

#### `dashboard.resources` — ダッシュボードのリソース制限

```yaml
  resources:
    requests:
      cpu: 20m
      memory: 64Mi
    limits:
      cpu: 200m
      memory: 128Mi
```

**コントローラーとの比較:**

| コンポーネント | CPU request | Memory request | CPU limit | Memory limit |
|--------------|-------------|----------------|-----------|--------------|
| controller | 50m | 128Mi | 500m | 256Mi |
| dashboard | 20m | 64Mi | 200m | 128Mi |

ダッシュボードは単純な Web UI のため、コントローラーよりも少ないリソースで動作する。
ユーザーがブラウザでアクセスしたときだけ CPU を消費し、普段はほぼアイドル状態。

---

### ArgoCD Application (`k8s/argocd/apps/argo-rollouts.yaml`) の解説

ArgoCD が Argo Rollouts を GitOps で管理するための定義ファイル。

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argo-rollouts
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "4"
```

**`sync-wave: "4"`:**
ArgoCD の起動順序制御。Wave 4 は「longhorn / vault / minio / cert-manager (Wave 2-3) が起動した後に起動する」ことを意味する。Argo Rollouts は他のアプリに依存しないが、pve-node01 NIC ハング防止のため段階的に起動する。

```yaml
spec:
  sources:
    - repoURL: https://argoproj.github.io/argo-helm
      chart: argo-rollouts
      targetRevision: "2.38.0"
      helm:
        valueFiles:
          - $values/k8s/argo-rollouts/values.yaml
    - repoURL: https://github.com/fukui-yuto/proxmox-lab
      targetRevision: HEAD
      ref: values
```

**マルチソース構成:**
- 1つ目のソース: 公式 Helm chart リポジトリから `argo-rollouts` chart v2.38.0 を取得
- 2つ目のソース: 自分の Git リポジトリから `values.yaml` を参照 (`$values` という参照名)
- `$values/k8s/argo-rollouts/values.yaml`: Git リポジトリ内のカスタム values ファイルのパス

**この仕組みのメリット:**
values.yaml を Git で管理できるため、設定変更は Git push するだけで ArgoCD が自動的に検出・適用する。

```yaml
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
      - RespectIgnoreDifferences=true
```

| 設定 | 意味 |
|------|------|
| `automated` | Git の変更を検出して自動で Sync する |
| `prune: true` | Git から削除されたリソースはクラスターからも削除する |
| `selfHeal: true` | 手動変更を検出して Git の状態に自動修復する |
| `CreateNamespace=true` | `argo-rollouts` namespace が存在しなければ自動作成 |
| `ServerSideApply=true` | 大きな CRD のフィールド競合を防ぐためサーバーサイド適用を使用 |
| `RespectIgnoreDifferences=true` | ignoreDifferences で指定した差分は Sync 時にも無視する |

```yaml
  ignoreDifferences:
    - group: apiextensions.k8s.io
      kind: CustomResourceDefinition
      jqPathExpressions:
        - .status
        - .metadata
        - .spec
```

**`ignoreDifferences` の目的:**
CRD リソースはコントローラーが動的にフィールドを追加・変更するため、Git 上の定義とクラスター上の実態に常に差分が生じる。この差分を無視することで、ArgoCD が「OutOfSync」と判定して不要な再同期を繰り返すことを防ぐ。
