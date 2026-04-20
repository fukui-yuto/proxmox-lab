# Argo Workflows 詳細ガイド — Kubernetes ネイティブのワークフローエンジン

## このツールが解決する問題

「複数のタスクを順番に・並列に実行したい」というのはよくある要件:

- コンテナイメージをビルド → テスト → デプロイ
- データを取得 → 加工 → 保存
- 障害検知 → 診断 → 自動修復

シェルスクリプトで繋ぐと、エラー処理・リトライ・並列実行・ログ管理が地獄になる。

| 問題 | 内容 |
|------|------|
| 依存関係の管理 | タスク A が終わったら B、B と C は並列、全部終わったら D |
| 再実行 | 途中で失敗したらそこから再実行したい |
| 可視化 | 今どこまで進んでいるか確認したい |
| リソース管理 | 各タスクに CPU/メモリ制限を個別に設定したい |

Argo Workflows は各タスク (Step) を独立した Pod として実行し、
DAG (有向非巡回グラフ) でタスク間の依存関係を宣言的に定義できる。

---

## ワークフローとは

```
┌─────────────────────────────────────────────┐
│  Workflow: build-and-deploy                  │
│                                             │
│  [clone-repo] ──→ [build-image] ──→ [push-image] ──→ [deploy]
│                         │
│                         └──→ [run-tests] ──→ (merge)
│                                                  ↓
│                                             [deploy]
└─────────────────────────────────────────────┘
```

各ボックスが1つの Pod (コンテナ) として実行される。
矢印は「このタスクが終わったら次を実行」という依存関係。

---

## Argo Workflows のアーキテクチャ

```
┌─────────────────────────────────────────────┐
│  Kubernetes クラスター                        │
│                                             │
│  ┌──────────────────┐  ┌─────────────────┐  │
│  │ Workflow          │  │ Argo Server     │  │
│  │ Controller        │  │ (Web UI / API)  │  │
│  │                  │  │                 │  │
│  │ Workflow CRD を   │  │ ブラウザで       │  │
│  │ 監視して Pod を    │  │ ワークフローを   │  │
│  │ 起動・管理        │  │ 確認・操作       │  │
│  └──────────────────┘  └─────────────────┘  │
│          │                                  │
│          ↓                                  │
│  ┌──────────────────────────────────────┐   │
│  │  Step Pod 1  │  Step Pod 2  │  ...   │   │
│  │  (各タスク)    │  (各タスク)    │       │   │
│  └──────────────────────────────────────┘   │
└─────────────────────────────────────────────┘
```

| コンポーネント | 役割 |
|--------------|------|
| **Workflow Controller** | Workflow リソースを監視して、Pod を作成・管理する |
| **Argo Server** | Web UI と REST API を提供。ワークフローの状態確認・手動実行 |
| **Workflow (CRD)** | 「こういう順番でタスクを実行して」という定義 |
| **Step Pod** | 各タスクが実行される Pod。終了したら自動削除 |

---

## ファイル構成と解説

### `values.yaml` — Argo Workflows の Helm 設定

```yaml
# Argo Workflows — homelab 向け最小構成
# chart: argo-workflows (https://argoproj.github.io/argo-helm)

controller:
  resources:
    requests:
      cpu: 100m        # Workflow Controller: Workflow の監視・Pod 管理
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
```

**controller** = ワークフローの頭脳。Workflow リソースが作られると検知して、
定義に従って Pod を順番に起動していく。

```yaml
server:
  enabled: true
  # auth-mode=server: ログイン不要 (homelab 用)
  # 本番では auth-mode=sso や auth-mode=client を使う
  extraArgs:
    - --auth-mode=server
  resources:
    requests:
      cpu: 50m         # Argo Server: Web UI の提供
      memory: 128Mi
    limits:
      cpu: 200m
      memory: 256Mi
  ingress:
    enabled: true
    ingressClassName: traefik                    # Traefik 経由で外部公開
    hosts:
      - argo-workflows.homelab.local            # ブラウザでアクセスする URL
    paths:
      - /
    pathType: Prefix
```

**server** = Web UI。`--auth-mode=server` はログイン無しでアクセス可能にする設定。
ラボ環境なので認証を省略している。

```yaml
workflow:
  serviceAccount:
    create: true       # Workflow が Pod を作るための ServiceAccount を自動作成
  rbac:
    create: true       # 必要な権限 (Role/RoleBinding) を自動作成
```

**workflow.serviceAccount** = ワークフローが Pod を作成するには Kubernetes の権限が必要。
`create: true` で必要な ServiceAccount と RBAC を自動設定してくれる。

---

## このラボでの使い方

このラボでは Argo Workflows は **aiops (自動修復)** の実行エンジンとして使っている:

```
Prometheus アラート発火
  → Argo Events がイベント受信
  → Argo Workflow をトリガー
  → 自動修復ワークフロー実行 (Pod 再起動、スケールアウトなど)
```

---

## Workflow の書き方 (例)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  name: hello-world
spec:
  entrypoint: main              # 最初に実行するテンプレート名
  templates:
    - name: main                # テンプレート定義
      steps:                    # steps: 順番に実行
        - - name: step1         # 第1ステップ
            template: echo
            arguments:
              parameters:
                - name: message
                  value: "Hello"
        - - name: step2         # 第2ステップ (step1 の後に実行)
            template: echo
            arguments:
              parameters:
                - name: message
                  value: "World"

    - name: echo                # 再利用可能なテンプレート
      inputs:
        parameters:
          - name: message
      container:
        image: alpine:3.18
        command: [echo]
        args: ["{{inputs.parameters.message}}"]
```

**ポイント:**
- `entrypoint`: 実行開始点のテンプレート名
- `templates`: タスクの定義 (関数のようなもの)
- `steps`: 順次実行 (同じリスト内は並列実行)
- `container`: 各タスクで動かすコンテナの定義

---

## DAG (並列・依存関係) の例

```yaml
templates:
  - name: main
    dag:
      tasks:
        - name: A
          template: task-a
        - name: B
          template: task-b
          dependencies: [A]       # A が終わったら B を実行
        - name: C
          template: task-c
          dependencies: [A]       # A が終わったら C も実行 (B と並列)
        - name: D
          template: task-d
          dependencies: [B, C]    # B と C の両方が終わったら D を実行
```

```
    A
   / \
  B   C    ← B と C は並列実行
   \ /
    D
```

---

## Argo Workflows vs 他のツール

| ツール | 特徴 | 適する場面 |
|--------|------|-----------|
| **Argo Workflows** | k8s ネイティブ、各 Step が Pod | CI/CD、データパイプライン、自動修復 |
| **CronJob** | 単発タスクの定期実行 | 単純な定期バッチ |
| **Jenkins** | 歴史が長い、プラグイン豊富 | レガシー CI/CD |
| **GitHub Actions** | GitHub に統合 | GitHub リポジトリの CI/CD |
