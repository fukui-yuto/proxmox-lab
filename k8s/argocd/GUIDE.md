# ArgoCD 詳細ガイド — GitOps 継続的デリバリー

## このツールが解決する問題

Kubernetes へのデプロイを手動でやると以下の問題が起きる:

```
問題:
  - kubectl apply を手動で実行するのを忘れる
  - 誰かが kubectl で直接変更してしまい、Git と実際の状態がズレる
  - 「今クラスターで動いているのはどのバージョンか」がわからない
  - ロールバックが手動で大変

解決:
  ArgoCD が Git を常に監視し、自動的にクラスターに同期する
  Git が唯一の真実 (Single Source of Truth)
```

---

## GitOps とは

**Git リポジトリをシステムの「あるべき姿」の唯一の正解として扱う運用手法**。

```
従来の運用:
  開発者 → kubectl apply → クラスター
  (Gitと実際の状態が乖離するリスクがある)

GitOps:
  開発者 → Git push → ArgoCD が検知 → クラスターに自動反映
  (Gitが唯一の正解、クラスターは常にGitと一致)
```

**GitOps の4原則 (OpenGitOps):**
1. **宣言的 (Declarative):** あるべき姿を YAML で宣言する
2. **バージョン管理 (Versioned):** Git で全変更履歴を管理する
3. **自動プル (Pulled automatically):** エージェントが Git から自動的に取得する
4. **継続的調整 (Continuously reconciled):** 定期的に実際の状態とあるべき姿を一致させる

---

## ArgoCD のコンポーネント

```
┌─────────────────────────────────────────────────────┐
│  ArgoCD                                             │
│                                                     │
│  API Server       ← CLI/UI/外部からのリクエスト処理   │
│  Repository Server← Git リポジトリからマニフェスト取得 │
│  Application Controller ← 実際のクラスターと照合・同期 │
│  ApplicationSet Controller ← Application を自動生成  │
│  Notifications Controller  ← Slack等への通知         │
│  Redis            ← キャッシュ                       │
└─────────────────────────────────────────────────────┘
```

### Application Controller の動作

Application Controller は **Desired State (あるべき姿)** と **Live State (実際の状態)** を比較し続ける。

```
Git (あるべき姿)         クラスター (実際の状態)
  replicas: 3      vs      replicas: 2  ← 差分あり → 同期
  image: v1.2.0    vs      image: v1.2.0 ← 同じ → OK
```

---

## Application リソース

ArgoCD における「何を」「どこから」「どこに」デプロイするかの定義。

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: monitoring          # Application の名前
  namespace: argocd
spec:
  project: default

  source:
    repoURL: https://github.com/xxx/proxmox-lab  # Git リポジトリ
    targetRevision: HEAD                          # ブランチ/タグ/コミット
    path: k8s/monitoring                          # リポジトリ内のパス

  destination:
    server: https://kubernetes.default.svc        # デプロイ先クラスター
    namespace: monitoring                         # デプロイ先 Namespace

  syncPolicy:
    automated:           # 自動同期の設定
      prune: true        # Git から削除されたリソースをクラスターからも削除
      selfHeal: true     # 手動変更を Git の状態に自動で戻す
```

### selfHeal とは

`selfHeal: true` の場合、誰かが `kubectl` で直接変更しても自動的に Git の状態に戻される。

```
kubectl scale deployment nginx --replicas=5
  ↓  (ArgoCD が検知)
ArgoCD が replicas: 3 (Git の値) に自動で戻す
```

これにより「クラスターの状態は常に Git と一致する」が保証される。

---

## Sync (同期) の仕組み

### Sync Wave

複数の Application ��順番に起動する仕組み。このラボで NIC ハング対策として使用している。

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "3"  # Wave 3 で起動
```

**動作:**
1. Wave 0 の全 Application が Healthy になるまで待つ
2. Wave 1 を起動 → Healthy になるまで待つ
3. Wave 2 を起動 → ...

```
Wave 0: kyverno ─────────────────────────────────────┐
Wave 1: kyverno-policies ───────────────────────────┐ │ 全て Healthy になったら次へ
Wave 2: vault ──────────────────────────────────────┤ │
Wave 3: monitoring ─────────────────────────────────┘ │
...                                                    ↓ 順番に起動
```

### Sync Hook

同期の特定タイミングでジョブを実行する仕組み。

```yaml
metadata:
  annotations:
    argocd.argoproj.io/hook: PreSync     # 同期前に実行
    argocd.argoproj.io/hook: PostSync    # 同期後に実行
    argocd.argoproj.io/hook: SyncFail   # 同期失敗時に実行
```

---

## Helm + ArgoCD の使い方

このラボでは多くのアプリを Helm chart からデプロイしている。
ArgoCD は Helm を内蔵しており、直接 Helm chart を参照できる。

```yaml
spec:
  sources:
    - repoURL: https://prometheus-community.github.io/helm-charts  # Helm リポジトリ
      chart: kube-prometheus-stack                                   # Chart 名
      targetRevision: "61.3.2"                                      # Chart バージョン
      helm:
        valueFiles:
          - $values/k8s/monitoring/values.yaml   # values ファイルの参照

    - repoURL: https://github.com/fukui-yuto/proxmox-lab  # values ファイルの Git リポジトリ
      targetRevision: HEAD
      ref: values   # "$values" として参照される
```

**`$values` の仕組み:**
2つ目の source を `ref: values` として登録することで、`$values/...` で参照できる。
これにより Helm chart は外部リポジトリから取得しつつ、values は自分の Git リポジトリで管理できる。

---

## App of Apps パターン

ArgoCD の Application 自体を ArgoCD で管理するパターン。

```
root Application (Git で管理)
    ↓ 同期
  monitoring Application
  logging Application
  tracing Application
  ...
```

このラボの `k8s/argocd/apps/` ディレクトリがこれに相当する。
ArgoCD をインストールした後、`apps/` 以下の Application を適用するだけで全アプリが管理下に入る。

---

## ArgoCD CLI コマンドリファレンス

```bash
# ログイン
argocd login argocd.homelab.local --username admin --insecure

# Application 一覧
argocd app list

# Application の���態確認
argocd app get monitoring

# 手動同期
argocd app sync monitoring

# 差分確認 (Git vs クラスター)
argocd app diff monitoring

# Application のログ確認
argocd app logs monitoring

# ロールバック (1つ前の状態に戻す)
argocd app rollback monitoring

# Application の削除 (--cascade でリソースも削除)
argocd app delete harbor --cascade

# 全 Application の同期状態確認
argocd app list -o wide
```

---

## Application の状態と意味

| 状態 | 意味 |
|------|------|
| `Synced` | Git とクラスターが一致している |
| `OutOfSync` | Git とクラスターに差分がある |
| `Healthy` | 全リソースが正常稼働中 |
| `Progressing` | デプロイ中 |
| `Degraded` | 一部リソースに問題がある |
| `Missing` | リソースがクラスターに存在しない |
| `Unknown` | 状態を確認できない |

---

## よく使うコマンド

```bash
# ArgoCD Pod の状態確認
kubectl get pods -n argocd

# ArgoCD Server のログ (UI/API のログ)
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server --tail=50

# Application Controller のログ (同期ログ)
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller --tail=50

# Repo Server のログ (Git 接続ログ)
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server --tail=50

# 全 Application の同期を強制実行
for app in $(argocd app list -o name); do
  argocd app sync $app
done
```

---

## トラブルシューティング

### Application が OutOfSync のまま自動同期しない

```bash
# 差分を確認
argocd app diff monitoring

# 手動で強制同期
argocd app sync monitoring --force

# selfHeal が有効か確認
argocd app get monitoring | grep "Auto Sync"
```

### Git リポジトリに接続できない

```bash
# Repo Server のログを確認
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server | grep -i error

# リポジトリ接続テスト (ArgoCD UI)
# Settings → Repositories → 対象リポジトリ → Connection Status
```

### Helm values が反映されない

ArgoCD の Repo Server がキャッシュしている場合がある。

```bash
# Application を手動でリフレッシュ
argocd app get monitoring --hard-refresh
```

---

## ファイル構成と各ファイルのコード解説

### ファイル構成一覧

```
k8s/argocd/
├── GUIDE.md                    # 本ガイド (概念説明・学習用)
├── README.md                   # 手順書
├── namespace.yaml              # argocd Namespace 定義
├── values-argocd.yaml          # ArgoCD Helm chart のカスタム values
├── root-app.yaml               # App of Apps ルートアプリケーション
├── install.sh                  # インストールスクリプト
└── apps/                       # 個別アプリの Application 定義
    ├── aiops.yaml              # AIOps 関連 (7つの Application を1ファイルに定義)
    ├── argo-events.yaml        # Argo Events
    ├── argo-rollouts.yaml      # Argo Rollouts
    ├── argo-workflows.yaml     # Argo Workflows
    ├── backstage.yaml          # Backstage 開発者ポータル
    ├── cert-manager.yaml       # cert-manager + Issuers
    ├── cilium.yaml             # Cilium CNI
    ├── crossplane.yaml         # Crossplane
    ├── falco.yaml              # Falco ランタイムセキュリティ
    ├── harbor.yaml             # Harbor コンテナレジストリ
    ├── keda.yaml               # KEDA オートスケーラー
    ├── keycloak.yaml           # Keycloak 認証基盤
    ├── kyverno.yaml            # Kyverno ポリシーエンジン
    ├── litmus.yaml             # Litmus カオスエンジニアリング
    ├── logging.yaml            # ログ基盤 (Elasticsearch/Fluent-bit/Kibana)
    ├── longhorn.yaml           # Longhorn 分散ストレージ
    ├── minio.yaml              # MinIO S3互換ストレージ
    ├── monitoring.yaml         # Prometheus/Grafana 監視
    ├── tracing.yaml            # Tempo/OTel 分散トレーシング
    ├── trivy-operator.yaml     # Trivy 脆弱性スキャン
    ├── vault.yaml              # HashiCorp Vault
    └── velero.yaml             # Velero バックアップ
```

---

### namespace.yaml の解説

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: argocd
```

ArgoCD が動作するための Namespace を定義する最もシンプルなファイル。ArgoCD の全コンポーネント (API Server, Application Controller, Repo Server など) はこの `argocd` Namespace にデプロイされる。

通常は `install.sh` スクリプト内で Helm インストール前にこの Namespace を作成する。Kubernetes では Namespace が存在しないとリソースをデプロイできないため、最初に作成する必要がある。

---

### values-argocd.yaml の全設定解説

このファイルは ArgoCD Helm chart (`argo/argo-cd` version 9.4.17) に渡すカスタム設定値。Helm chart のデフォルト値をこのファイルで上書きする。

#### global セクション

```yaml
global:
  domain: argocd.homelab.local
```

ArgoCD が自身のドメイン名として認識する値。Ingress の hostname や OIDC のリダイレクト URL 生成に使用される。このラボでは TLS を使わず HTTP のみで通信するため、外部 (Traefik) が TLS 終端を担当する構成。

#### configs.secret — 管理者パスワード

```yaml
configs:
  secret:
    argocdServerAdminPassword: "$2a$10$1n/U6oGHF0IbhbQZoBeQtu1IwUB7QYgfMV7p/jmHHgznOWi0d3xP6"
```

`admin` ユーザーのパスワードを bcrypt ハッシュで固定化している。平文は `Argocd12345`。

**なぜハッシュ化するか:** ArgoCD はパスワードを Secret に bcrypt 形式で保存する設計になっている。平文を直接書くことはできないため、事前に `htpasswd -nbBC 10 "" Argocd12345 | tr -d ':\n'` などで生成したハッシュ値を記述する。

**なぜ固定化するか:** デフォルトでは ArgoCD 初回インストール時にランダムなパスワードが生成される。ラボ環境では再インストールのたびにパスワードが変わると面倒なため固定値にしている。

#### configs.cm — ArgoCD ConfigMap 設定

```yaml
configs:
  cm:
    url: http://argocd.homelab.local
    oidc.config: |
      name: Keycloak
      issuer: http://keycloak.homelab.local/realms/homelab
      clientID: argocd
      clientSecret: argocd-keycloak-secret-2026
      requestedScopes:
        - openid
        - profile
        - email
        - groups
      requestedIDTokenClaims:
        groups:
          essential: true
```

**`url`:** ArgoCD の外部公開 URL。OIDC ログイン後のコールバック先として使われる。`http://` なのは TLS をこのラボでは使っていないため。

**`oidc.config`:** Keycloak との SSO 連携設定。各項目の意味:

| 項目 | 説明 |
|------|------|
| `name` | ログイン画面に表示されるボタン名 ("Log in via Keycloak") |
| `issuer` | Keycloak の OpenID Connect Discovery エンドポイントのベース URL |
| `clientID` | Keycloak 側で作成した ArgoCD 用クライアントの ID |
| `clientSecret` | クライアントシークレット (Keycloak 管理画面で確認) |
| `requestedScopes` | ユーザー情報取得に必要なスコープ。`groups` でグループ情報を取得する |
| `requestedIDTokenClaims` | ID トークンに必ず含めてほしいクレーム。`groups` を必須にすることで RBAC に利用する |

#### configs.rbac — ロールベースアクセス制御

```yaml
configs:
  rbac:
    policy.default: role:readonly
    policy.csv: |
      g, homelab-admins, role:admin
```

- `policy.default: role:readonly` — 認証されたがグループに属さないユーザーは読み取り専用
- `g, homelab-admins, role:admin` — Keycloak の `homelab-admins` グループに属するユーザーに admin 権限を付与

これにより Keycloak のグループ管理だけで ArgoCD の権限を制御できる。

#### server セクション — API Server 設定

```yaml
server:
  extraArgs:
    - --insecure
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 300m
      memory: 256Mi
  ingress:
    enabled: true
    ingressClassName: traefik
    hostname: argocd.homelab.local
    tls: false
```

**`--insecure`:** ArgoCD Server の内部 HTTPS を無効化し HTTP で動作させる。このラボでは Traefik (Ingress Controller) が外部からの通信を受け付けるため、ArgoCD 自身が TLS を処理する必要がない。これにより証明書管理の複雑さを排除している。

**`resources`:** ホームラボの限られたリソースに合わせた軽量設定。API Server は UI 表示やリクエスト処理を行うが、重い処理は Application Controller が担うため比較的少ないリソースで動作する。

**`ingress`:** Traefik 経由で `argocd.homelab.local` でアクセスできるようにする設定。`tls: false` は Ingress リソースに TLS 設定を付けないことを意味する (ArgoCD 自体が `--insecure` で HTTP のみなので一貫している)。

#### controller セクション — Application Controller 設定

```yaml
controller:
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 2Gi
```

Application Controller は ArgoCD で最もリソースを消費するコンポーネント。全 Application の状態を定期的にチェックし、Git との差分を検出し、同期処理を実行する。このラボでは 20以上の Application を管理しているため、メモリ上限を **2Gi** と大きめに設定している。メモリが不足すると OOMKilled で Controller が落ち、全ての同期が停止してしまう。

#### repoServer セクション — Repository Server 設定

```yaml
repoServer:
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 1Gi
  livenessProbe:
    httpGet:
      path: /healthz
      port: metrics
    initialDelaySeconds: 10
    periodSeconds: 10
    timeoutSeconds: 15
    failureThreshold: 5
```

Repo Server は Git リポジトリからマニフェストを取得し、Helm template のレンダリングや Kustomize のビルドを実行する。Helm chart が多い環境ではレンダリング処理に時間がかかることがあるため、メモリを **1Gi** まで許可している。

**`livenessProbe`** を明示的に設定している理由: 多数の Helm chart を同時にレンダリングすると一時的にレスポンスが遅くなることがある。デフォルトのタイムアウトでは不十分な場合があるため、`timeoutSeconds: 15`、`failureThreshold: 5` と緩めに設定し、一時的な遅延で Pod が再起動されないようにしている。

#### その他のコンポーネント (applicationSet, notifications, redis)

```yaml
applicationSet:
  resources:
    limits: { cpu: 100m, memory: 128Mi }

notifications:
  resources:
    limits: { cpu: 100m, memory: 128Mi }

redis:
  resources:
    limits: { cpu: 100m, memory: 128Mi }
```

いずれもラボ環境に合わせた軽量設定。このラボでは ApplicationSet (テンプレートから Application を自動生成) や Notifications (Slack 通知等) は活用していないため最小限のリソースを割り当てている。Redis は ArgoCD 内部のキャッシュとして使われるが、軽量な用途のため少量で十分。

---

### root-app.yaml の詳細解説

このファイルは **App of Apps パターン** の「ルートアプリケーション」。ArgoCD で管理する全アプリの「親」にあたる。

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
  finalizers: []
```

**`name: root`:** 慣例的にルートアプリケーションには `root` という名前を付ける。ArgoCD UI のツリー表示でこのアプリが最上位に表示される。

**`finalizers: []`:** 空配列を明示することで、この Application を削除してもカスケード削除 (子 Application の削除) が発生しないようにしている。通常 ArgoCD は Application 削除時に管理下のリソースも削除するが、root app を誤って削除した場合に全アプリが消えるのを防止する安全策。

#### spec.source — 監視対象

```yaml
spec:
  source:
    repoURL: https://github.com/fukui-yuto/proxmox-lab
    targetRevision: HEAD
    path: k8s/argocd/apps
```

Git リポジトリの `k8s/argocd/apps` ディレクトリを監視する。このディレクトリ内の全 YAML ファイル (Application リソース定義) を自動的に検出してクラスターに適用する。新しいファイルを追加して `git push` すれば、自動的に新しい Application が作成される。

#### spec.destination — デプロイ先

```yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
```

`apps/` ディレクトリ内のリソース (Application) は `argocd` Namespace にデプロイされる。Application リソース自体は ArgoCD が管理するため、ArgoCD と同じ Namespace に置く。

#### spec.syncPolicy — 自動同期設定

```yaml
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=false
      - ServerSideApply=true
      - RespectIgnoreDifferences=true
```

| 設定 | 効果 |
|------|------|
| `automated` | Git に変更があれば自動で同期を実行する |
| `prune: true` | Git から YAML を削除したら、対応する Application もクラスターから削除する |
| `selfHeal: true` | 手動で Application を変更しても、Git の状態に自動で戻す |
| `CreateNamespace=false` | argocd Namespace は既に存在するので作成しない |
| `ServerSideApply=true` | `kubectl apply` ではなく Server-Side Apply を使う (後述) |
| `RespectIgnoreDifferences=true` | ignoreDifferences で除外した差分を同期時にも無視する |

**ServerSideApply とは:**
通常の `kubectl apply` (Client-Side Apply) ではマニフェストの `last-applied-configuration` アノテーションを使って差分を計算する。Server-Side Apply では Kubernetes API Server が直接フィールドの所有者を追跡するため、複数のコントローラーが同じリソースを更新する場合でもコンフリクトが起きにくい。

ArgoCD で ServerSideApply を使う理由:
- Application リソースは ArgoCD 自身も `status` フィールドを更新するため、Client-Side Apply だとコンフリクトが発生しやすい
- CRD のような大きなリソースで `last-applied-configuration` アノテーションが 262144バイト制限を超えるのを防ぐ

**RespectIgnoreDifferences とは:**
`ignoreDifferences` で「この差分は無視する」と設定した場合でも、デフォルトでは同期時にはその差分を上書きしてしまう。`RespectIgnoreDifferences=true` を設定することで、同期時にも ignoreDifferences で指定したフィールドを一切触らないようになる。

#### spec.ignoreDifferences — 差分無視設定

```yaml
  ignoreDifferences:
    - group: argoproj.io
      kind: Application
      jsonPointers:
        - /status
        - /operation
```

ArgoCD が管理する Application リソースには、ArgoCD 自身が `/status` (同期状態・ヘルス状態) と `/operation` (実行中の操作) を随時書き込む。これらは Git には存在しないフィールドなので、差分として検出されると「常に OutOfSync」になってしまう。`ignoreDifferences` でこれらのフィールドを差分検出から除外することで、正常に Synced 状態を維持できる。

---

### apps/ ディレクトリのアプリ定義パターン解説

`apps/` ディレクトリ内の各 YAML ファイルは、ArgoCD Application リソースを定義する。root-app がこのディレクトリを監視しているため、ファイルを追加・変更・削除するだけで Application が自動的に作成・更新・削除される。

以下に代表的な3つのパターンを解説する。

#### パターン1: 基本パターン (monitoring.yaml)

外部 Helm chart + Git の values ファイルを組み合わせる最も一般的なパターン。

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: monitoring
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "4"
spec:
  project: default
  sources:
    - repoURL: https://prometheus-community.github.io/helm-charts
      chart: kube-prometheus-stack
      targetRevision: "61.3.2"
      helm:
        valueFiles:
          - $values/k8s/monitoring/values.yaml
    - repoURL: https://github.com/fukui-yuto/proxmox-lab
      targetRevision: HEAD
      ref: values
    - repoURL: https://github.com/fukui-yuto/proxmox-lab
      targetRevision: HEAD
      path: k8s/monitoring/dashboards
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

**構造の解説:**

このファイルは `sources` (複数形) を使った **マルチソース Application**。3つのソースを組み合わせている:

**ソース1 — Helm chart 本体:**
```yaml
- repoURL: https://prometheus-community.github.io/helm-charts  # Helm リポジトリ URL
  chart: kube-prometheus-stack                                   # chart 名
  targetRevision: "61.3.2"                                      # chart バージョン (固定)
  helm:
    valueFiles:
      - $values/k8s/monitoring/values.yaml   # values ファイルのパス ($values 参照)
```
外部の Helm リポジトリから chart をダウンロードし、カスタム values で設定を上書きする。`targetRevision` でバージョンを固定することで、意図しないアップグレードを防止する。

**ソース2 — values ファイルの Git 参照:**
```yaml
- repoURL: https://github.com/fukui-yuto/proxmox-lab
  targetRevision: HEAD
  ref: values    # ← これがポイント
```
`ref: values` と指定することで、このソースを `$values` という変数名で参照できるようになる。ソース1の `$values/k8s/monitoring/values.yaml` はこのリポジトリの該当パスに解決される。

**なぜ2つのソースに分けるか:**
- Helm chart は外部リポジトリ (prometheus-community) にある
- values ファイルは自分のリポジトリ (proxmox-lab) にある
- ArgoCD のマルチソース機能で両方を1つの Application から参照できる

**ソース3 — 追加マニフェスト:**
```yaml
- repoURL: https://github.com/fukui-yuto/proxmox-lab
  targetRevision: HEAD
  path: k8s/monitoring/dashboards
```
Helm chart だけでは足りない追加リソース (Grafana ダッシュボード用 ConfigMap など) を Git のディレクトリから直接デプロイする。`path` を指定すると、そのディレクトリ内の全 YAML が適用される。

**syncPolicy の各オプション:**
- `CreateNamespace=true` — `monitoring` Namespace が存在しなければ自動作成する
- `ServerSideApply=true` — kube-prometheus-stack は大量の CRD を含むため、SSA が必須

#### パターン2: マルチソースパターン (longhorn.yaml)

1つのファイルに **複数の Application** を定義し、前提条件 (prereqs) と本体を分けるパターン。

```yaml
---
# longhorn-prereqs: open-iscsi インストール DaemonSet
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: longhorn-prereqs
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  project: default
  source:
    repoURL: https://github.com/fukui-yuto/proxmox-lab
    targetRevision: HEAD
    path: k8s/longhorn
    directory:
      include: "{namespace.yaml,iscsi-installer.yaml}"
  destination:
    server: https://kubernetes.default.svc
    namespace: longhorn-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

**ポイント: `directory.include` による部分的なデプロイ**

```yaml
directory:
  include: "{namespace.yaml,iscsi-installer.yaml}"
```

`path` でディレクトリを指定しつつ、`directory.include` で特定のファイルだけを選択的にデプロイできる。これにより1つの `k8s/longhorn/` ディレクトリに全ファイルを置きつつ、Application ごとに適用するファイルを制御できる。

glob パターンが使用可能で、`{a.yaml,b.yaml}` は「a.yaml または b.yaml」の意味。

**2つ目の Application — Longhorn 本体:**

```yaml
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: longhorn
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  ...
  syncPolicy:
    syncOptions:
      - ServerSideApply=true
      - RespectIgnoreDifferences=true
  ignoreDifferences:
    - group: apiextensions.k8s.io
      kind: CustomResourceDefinition
      jqPathExpressions:
        - .status
        - .metadata
        - .spec
```

**ignoreDifferences の実践例:**

Longhorn は多数の CRD (CustomResourceDefinition) を含む。CRD は Kubernetes コントローラーが `status` や `metadata` (アノテーション等) を自動更新するため、Git に定義した内容と実際の状態が常にズレる。このズレを「差分」として扱うと永久に OutOfSync になるため、`ignoreDifferences` で除外する。

`jqPathExpressions` は jq の構文でフィールドを指定できる。`jsonPointers` より柔軟な指定が可能:
- `jsonPointers`: `/status` (JSON Pointer 形式、配列内の要素指定が難しい)
- `jqPathExpressions`: `.status`, `.spec.versions[].schema` (jq 構文、配列操作が容易)

**なぜ prereqs と本体を分けるか:**

Longhorn は iSCSI (ブロックストレージプロトコル) を前提として動作する。各ノードに `open-iscsi` パッケージがインストールされていないと Longhorn のボリュームが作成できない。`longhorn-prereqs` が DaemonSet で全ノードに iSCSI をインストールし、その後 `longhorn` 本体がデプロイされる。同じ Sync Wave 内でも、prereqs の方が先に Healthy になるため正常に動作する。

#### パターン3: マルチアプリパターン (aiops.yaml)

関連する複数の Application を **1つのファイルにまとめて定義** するパターン。

```yaml
---
# image-build: aiops イメージ自動ビルド CI
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: aiops-image-build
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "12"
spec:
  ...
---
# alerting: PrometheusRule
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: aiops-alerting
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "12"
spec:
  ...
---
# alert-summarizer: LLM アラートサマリ
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: aiops-alert-summarizer
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "13"
spec:
  ...
```

**このパターンの特徴:**

1. **YAML ドキュメントセパレータ `---`** で区切ることで、1ファイルに複数のリソースを定義できる
2. 関連するアプリ (aiops の各コンポーネント) を1ファイルにまとめることで管理しやすくする
3. 各 Application に **異なる Sync Wave** を設定できるため、依存関係に応じた起動順序を制御可能

**aiops.yaml に含まれる7つの Application:**

| Application 名 | Wave | 役割 | デプロイ先 |
|----------------|------|------|-----------|
| `aiops-image-build` | 12 | Docker イメージ自動ビルド (CronWorkflow) | aiops |
| `aiops-alerting` | 12 | 予測アラートルール (PrometheusRule) | monitoring |
| `aiops-pushgateway` | 12 | 異常検知メトリクス受け口 (Helm chart) | monitoring |
| `aiops-alert-summarizer` | 13 | LLM によるアラート要約 | aiops |
| `aiops-anomaly-detection` | 13 | ログ異常検知 (CronJob) | aiops |
| `aiops-auto-remediation` | 14 | 自動修復ワークフロー (RBAC + Template) | aiops |
| `aiops-auto-remediation-events` | 15 | Argo Events 連携 (EventSource/Sensor) | argo-events |

**注目ポイント — Namespace の使い分け:**
全て "aiops" 系のアプリだが、デプロイ先 Namespace は異なる場合がある:
- PrometheusRule は Prometheus が監視する `monitoring` Namespace にデプロイ
- Argo Events リソースは `argo-events` Namespace にデプロイ
- 本体のワークロードは `aiops` Namespace にデプロイ

これはリソースの種類に応じて適切な Namespace に配置する設計。Application の `destination.namespace` で制御する。

**`directory.recurse` と `directory.exclude` の活用:**
```yaml
source:
  path: k8s/aiops/auto-remediation
  directory:
    recurse: true
    exclude: "{kaniko-job.yaml,runner/**,argo-events/**}"
```
- `recurse: true` — サブディレクトリも再帰的に探索する
- `exclude` — 特定のファイルやディレクトリを除外する (glob パターン)

これにより、1つのディレクトリツリーを複数の Application で分割管理できる。上記の例では `argo-events/` サブディレクトリは別の Application (`aiops-auto-remediation-events`) が管理するため除外している。

---

### Sync Wave の仕組み

Sync Wave はアプリの起動順序を制御するための ArgoCD 機能。アノテーションに数値を指定するだけで使える。

#### 設定方法

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "4"   # Wave 4 で起動
```

#### 動作原理

1. root-app が `apps/` ディレクトリの全 Application を検出する
2. Sync Wave の数値が小さい順にグループ分けされる
3. **Wave 0** の全 Application を同期 → 全て Healthy になるまで待機
4. **Wave 1** の全 Application を同期 → 全て Healthy になるまで待機
5. 以下同様に Wave の小さい順に進行する

```
時間軸 →→→→→→→→→→→→→→→→→→→→→→→→→→→→→→→→→→→→→→→→→→→→→→→→

Wave 0: [kyverno: 起動 → Healthy ✓]
Wave 1:                              [kyverno-policies: 起動 → Healthy ✓]
Wave 2:                                                                   [longhorn: 起動 → Healthy ✓]
Wave 3:                                                                                                [vault: 起動...]
...
```

#### このラボで Sync Wave を使う理由

pve-node01 の NIC (e1000e) にハードウェアバグがあり、大量のネットワーク通信が同時に発生するとハングする。全アプリを一斉に起動すると Docker イメージのプルが集中して NIC がハングし、Corosync クォーラムが喪失 → クラスター全体がクラッシュする。

Sync Wave で起動を段階的に分散することで、ネットワーク負荷のピークを抑制し、NIC ハングを防止している。

#### Wave 番号の設計方針

| 原則 | 説明 |
|------|------|
| 基盤サービスは小さい番号 | 他のアプリが依存するもの (Kyverno, Longhorn, Vault) を先に起動 |
| 依存関係を反映 | 例: Argo Events (Wave 4) が先に起動 → aiops-auto-remediation-events (Wave 15) が後から起動 |
| 同じ番号は並列起動 | 同じ Wave 内のアプリは同時に同期が始まる |
| 重いアプリは分散 | イメージサイズが大きいアプリ (Harbor, Keycloak) を別の Wave に分ける |

#### 注意点

- Sync Wave は **root-app 経由の同期でのみ有効**。個別に `argocd app sync monitoring` を手動実行した場合は Wave に関係なく即座に同期される
- Wave 内の1つのアプリが Degraded のまま Healthy にならないと、以降の Wave が永久に開始されない。トラブル時は手動同期で回避する
- 数値は文字列として指定する (`"4"` であり `4` ではない)

---

### apps/ 全22ファイル 個別解説

以下、Sync Wave 順に全ファイルを解説する。

---

#### cilium.yaml — CNI ネットワークプラグイン

| 項目 | 値 |
|------|-----|
| Wave | 0 |
| Helm chart | `cilium/cilium` v1.16.4 |
| namespace | `kube-system` |
| values | `k8s/cilium/values.yaml` |

```yaml
syncOptions:
  - CreateNamespace=false      # kube-system は既存
  - ServerSideApply=true       # CRD が大きいため SSA 必須
ignoreDifferences:
  - kind: Secret               # Cilium が自動生成する TLS 証明書 Secret
    jsonPointers: [/data]
  - group: monitoring.coreos.com
    kind: ServiceMonitor       # Prometheus Operator が spec を更新するため
    jsonPointers: [/spec]
```

**ポイント:**
- CNI は Pod ネットワークの基盤なので Wave 0（最優先）
- `kube-system` に配置されるため `CreateNamespace=false`
- flannel からの移行完了後に有効化された

---

#### kyverno.yaml — ポリシーエンジン (2つの Application)

**Application 1: kyverno (本体)**

| 項目 | 値 |
|------|-----|
| Wave | 0 |
| Helm chart | `kyverno/kyverno` v3.2.6 |
| namespace | `kyverno` |
| values | `k8s/kyverno/values-kyverno.yaml` |

**Application 2: kyverno-policies**

| 項目 | 値 |
|------|-----|
| Wave | 1 |
| ソース | Git: `k8s/kyverno/policies` ディレクトリ |
| namespace | `kyverno` |

**ポイント:**
- Kyverno は Admission Webhook でポリシーを強制するため、最初に起動する必要がある (Wave 0)
- ポリシー定義は Kyverno コントローラーが起動してからでないと適用できないため Wave 1
- 1ファイルで `---` セパレータにより2つの Application を定義

---

#### longhorn.yaml — 分散ブロックストレージ (2つの Application)

**Application 1: longhorn-prereqs**

| 項目 | 値 |
|------|-----|
| Wave | 2 |
| ソース | Git: `k8s/longhorn` の `namespace.yaml` + `iscsi-installer.yaml` のみ |
| namespace | `longhorn-system` |

**Application 2: longhorn (本体)**

| 項目 | 値 |
|------|-----|
| Wave | 2 |
| Helm chart | `longhorn/longhorn` v1.6.2 |
| namespace | `longhorn-system` |
| values | `k8s/longhorn/values-longhorn.yaml` |

```yaml
ignoreDifferences:
  - group: apiextensions.k8s.io
    kind: CustomResourceDefinition
    jqPathExpressions:
      - .status      # CRD の status はコントローラーが更新
      - .metadata    # アノテーション等が自動付与される
      - .spec        # spec.versions のスキーマが動的に変わる
```

**ポイント:**
- iSCSI が全ノード���インストールされていないと Longhorn が動かないため、prereqs で DaemonSet を先にデプロイ
- `directory.include` で特定ファイルだけを選択的にデプロイ
- CRD の ignoreDifferences が広い (`.spec` 全体) のは Longhorn の CRD が非常に大きく差分が頻発するため

---

#### vault.yaml — シークレット管理

| 項目 | 値 |
|------|-----|
| Wave | 3 |
| Helm chart | `hashicorp/vault` v0.28.0 |
| namespace | `vault` |
| values | `k8s/vault/values-vault.yaml` |

```yaml
ignoreDifferences:
  - group: apps
    kind: StatefulSet
    jsonPointers:
      - /spec/template/spec/containers/0/readinessProbe
  - group: admissionregistration.k8s.io
    kind: MutatingWebhookConfiguration
    jsonPointers:
      - /webhooks
```

**ポイント:**
- Vault は StatefulSet で動作し、初回デプロイ後に手動で `vault operator init` + `vault operator unseal` が必要
- readinessProbe を ignoreDifferences にしている理由: Vault が sealed 状態では Probe が失敗するため、ArgoCD が常に OutOfSync と判定してしまうのを防止
- MutatingWebhookConfiguration は Vault Agent Injector が CA バンドルを自動注入するため差分が出る

---

#### minio.yaml — S3 互換オブジェクトストレージ

| 項目 | 値 |
|------|-----|
| Wave | 3 |
| Helm chart | `minio/minio` v5.2.0 |
| namespace | `minio` |
| values | `k8s/minio/values-minio.yaml` |

**ポイント:**
- Velero のバックアップ保存先として使用されるため、Velero (Wave 4) より先に起動
- シンプルな Helm + values パターン。特別な ignoreDifferences なし

---

#### cert-manager.yaml — TLS 証明書管理 (2つの Application)

**Application 1: cert-manager (本体)**

| 項目 | 値 |
|------|-----|
| Wave | 3 |
| Helm chart | `jetstack/cert-manager` v1.14.5 |
| namespace | `cert-manager` |
| values | `k8s/cert-manager/values-cert-manager.yaml` |

**Application 2: cert-manager-issuers**

| 項目 | 値 |
|------|-----|
| Wave | 4 |
| ソース | Git: `k8s/cert-manager/cluster-issuers.yaml` のみ |
| namespace | `cert-manager` |

**ポイント:**
- cert-manager コントローラーが先に起動していないと ClusterIssuer を作成できないため、本体 (Wave 3) → Issuers (Wave 4) の順
- `directory.include: "cluster-issuers.yaml"` で1ファイルだけ選択的にデプロイ
- SSA 有効 (CRD を含むため)

---

#### monitoring.yaml — Prometheus + Grafana 監視スタック

| 項目 | 値 |
|------|-----|
| Wave | 4 |
| Helm chart | `prometheus-community/kube-prometheus-stack` v61.3.2 |
| namespace | `monitoring` |
| values | `k8s/monitoring/values.yaml` |
| 追加ソース | `k8s/monitoring/dashboards` (Grafana ダッシュボード) |

**ポイント:**
- 3つのソースを使うマルチソースパターン: Helm chart + values 参照 + 追加マニフェスト
- kube-prometheus-stack は Prometheus / Grafana / Alertmanager / node-exporter / kube-state-metrics を一括デプロイ
- ダッシュボード (ConfigMap) を別ソースとして追加し、values とは独立に管理

---

#### argo-workflows.yaml — ワークフローエンジン

| 項目 | 値 |
|------|-----|
| Wave | 4 |
| Helm chart | `argoproj/argo-workflows` v0.45.7 |
| namespace | `argo` |
| values | `k8s/argo-workflows/values.yaml` |

**ポイント:**
- AIOps の自動修復ワークフロー (Wave 14) の実行基盤なので先に起動
- シンプルな Helm + values パターン

---

#### argo-events.yaml — イベント駆動トリガー

| 項目 | 値 |
|------|-----|
| Wave | 4 |
| Helm chart | `argoproj/argo-events` v2.4.9 |
| namespace | `argo-events` |
| values | `k8s/argo-events/values.yaml` |

**ポイント:**
- Alertmanager → EventSource → Sensor → Workflow のイベントチェーンの基盤
- aiops-auto-remediation-events (Wave 15) が EventSource/Sensor を定義するため、コントローラーを先に起動

---

#### velero.yaml — k8s バックアップ/リストア

| 項目 | 値 |
|------|-----|
| Wave | 4 |
| Helm chart | `vmware-tanzu/velero` v7.1.4 |
| namespace | `velero` |
| values | `k8s/velero/values-velero.yaml` |

```yaml
ignoreDifferences:
  - group: rbac.authorization.k8s.io
    kind: ClusterRole
    name: velero-upgrade-crds
    jsonPointers: [/rules]
  - group: rbac.authorization.k8s.io
    kind: ClusterRoleBinding
    name: velero-upgrade-crds
    jsonPointers: [/subjects]
```

**ポイント:**
- MinIO (Wave 3) が先に起動している必要がある (バックアップ保存先)
- Velero Helm chart は CRD アップグレード用の ClusterRole/Binding を一時的に作成・削除するため、そのタイミングで差分が出る → ignoreDifferences で除外

---

#### argo-rollouts.yaml — プログレッシブデリバリー

| 項目 | 値 |
|------|-----|
| Wave | 4 |
| Helm chart | `argoproj/argo-rollouts` v2.38.0 |
| namespace | `argo-rollouts` |
| values | `k8s/argo-rollouts/values.yaml` |

```yaml
ignoreDifferences:
  - group: apiextensions.k8s.io
    kind: CustomResourceDefinition
    jqPathExpressions:
      - .status
      - .metadata
      - .spec
```

**ポイント:**
- カナリアデプロイ / Blue-Green デ��ロイを実現する CRD コントローラー
- CRD の ignoreDifferences は Longhorn と同じパターン (大きな CRD の自動更新差分を無視)

---

#### keda.yaml — イベント駆動オートスケーリング

| 項目 | 値 |
|------|-----|
| Wave | 4 |
| Helm chart | `kedacore/keda` v2.16.0 |
| namespace | `keda` |
| values | `k8s/keda/values.yaml` |

**ポイント:**
- Prometheus メトリクスや外部イベントソースに基づいて Pod を自動スケーリング
- SSA ���効 (ScaledObject 等の CRD を含む)
- シンプルなパターン、ignoreDifferences なし

---

#### falco.yaml — ランタイム脅威検知

| 項目 | 値 |
|------|-----|
| Wave | 4 |
| Helm chart | `falcosecurity/falco` v5.0.0 |
| namespace | `falco` |
| values | `k8s/falco/values.yaml` |

```yaml
ignoreDifferences:
  - group: apps
    kind: StatefulSet
    name: falco-falcosidekick-ui-redis
    jsonPointers:
      - /spec/volumeClaimTemplates
```

**ポイント:**
- カーネルの syscall を監視してコンテナ内の不審な動作 (シェル起動、ファイル改ざん等) を検知
- Redis の StatefulSet で `volumeClaimTemplates` の差分が出る理由: Helm chart 更新時に PVC テンプレートが変わっても既存 StatefulSet の PVC は変更不能なため

---

#### harbor.yaml — コンテナレジストリ

| 項目 | 値 |
|------|-----|
| Wave | 5 |
| Helm chart | `goharbor/harbor` v1.14.2 |
| namespace | `harbor` |
| values | `k8s/harbor/values-harbor.yaml` |

```yaml
ignoreDifferences:
  - kind: Secret
    name: harbor-core / harbor-jobservice / harbor-registry / harbor-registry-htpasswd
    jsonPointers: [/data]
  - group: apps
    kind: Deployment
    namespace: harbor
    jsonPointers: [/spec/template/metadata/annotations]
```

**ポイント:**
- Harbor は初回インストール時に複数の Secret をランダム値で生成する。以降 Harbor 自身がこれらを管理するため ArgoCD の diff から除外
- Deployment のアノテーション差分は Harbor コントローラーが Pod テンプレートにチェックサムを追記するために発生
- `RespectIgnoreDifferences=true` により sync 時にもこれらのフィールドを上書きしない

---

#### trivy-operator.yaml — 脆弱性スキャン

| 項目 | 値 |
|------|-----|
| Wave | 5 |
| Helm chart | `aquasecurity/trivy-operator` v0.24.1 |
| namespace | `trivy-system` |
| values | `k8s/trivy-operator/values.yaml` |

**ポイント:**
- クラスター内の全コンテナイメージを定期スキャンし、VulnerabilityReport CRD にレポートを保存
- Harbor (同じ Wave 5) と連携してプライベートレジストリのイメージもスキャン可能
- シンプルなパターン、SSA 有効

---

#### keycloak.yaml — SSO / OIDC 認証基盤

| 項目 | 値 |
|------|-----|
| Wave | 6 |
| ソース | Git: `k8s/keycloak/keycloak.yaml` のみ |
| namespace | `keycloak` |

**ポイント:**
- Helm chart ではなく **生マニフェスト** で���理している (Keycloak Operator の CR を直接定義)
- `directory.include: "keycloak.yaml"` で特定ファイルのみデプロイ
- Wave 6 にした理由: Grafana / ArgoCD 等が Keycloak に SSO 連携するが、Keycloak が起動していなくてもアプリ自体は動作する (ログインできないだけ)。重いアプリなので遅めに起動

---

#### logging.yaml — ログ基盤 (3つの Application)

**Application 1: logging-elasticsearch**

| 項目 | 値 |
|------|-----|
| Wave | 7 |
| Helm chart | `elastic/elasticsearch` v8.5.1 |
| namespace | `logging` |
| values | `k8s/logging/values-elasticsearch.yaml` |
| 追加ソース | `k8s/logging/elasticsearch-ingress.yaml` |

```yaml
ignoreDifferences:
  - kind: Secret
    name: elasticsearch-master-credentials
    namespace: logging
    jsonPointers: [/data]    # ランダムパスワード自動生成
```

**Application 2: logging-fluent-bit**

| 項目 | 値 |
|------|-----|
| Wave | 8 |
| Helm chart | `fluent/fluent-bit` v0.47.9 |
| namespace | `logging` |
| values | `k8s/logging/values-fluent-bit.yaml` |

**Application 3: logging-kibana**

| 項目 | 値 |
|------|-----|
| Wave | 9 |
| ソース | Git: `k8s/logging` の `kibana.yaml` + `kibana-ingress.yaml` + `oauth2-proxy.yaml` |
| namespace | `logging` |

**ポイント:**
- 3つを異なる Wave に分けている理由: Elasticsearch (Wave 7) が起動 → Fluent Bit (Wave 8) がログ送信開始 → Kibana (Wave 9) で可視化、という依存順序
- Kibana は Helm chart ではなく生マニフェストで管理 (oauth2-proxy を含む Keycloak SSO 統合のため)
- Elasticsearch の Secret は初回起動時にランダムパスワードが生成されるため ignoreDifferences

---

#### tracing.yaml — 分散トレーシング (2つの Application)

**Application 1: tracing-tempo**

| 項目 | 値 |
|------|-----|
| Wave | 10 |
| Helm chart | `grafana/tempo` v1.7.2 |
| namespace | `tracing` |
| values | `k8s/tracing/values-tempo.yaml` |

**Application 2: tracing-otel-collector**

| 項目 | 値 |
|------|-----|
| Wave | 11 |
| Helm chart | `open-telemetry/opentelemetry-collector` v0.97.1 |
| namespace | `tracing` |
| values | `k8s/tracing/values-otel-collector.yaml` |

**ポイント:**
- Tempo (保存先) が先に起動 → OTel Collector (収集・転送) が後から起動
- OTel Collector はアプリから受け取ったトレースを Tempo に転送するため、Tempo が Healthy でないとデータロストする

---

#### aiops.yaml — AIOps 全コンポーネント (7つの Application)

| Application 名 | Wave | Helm/Git | namespace | 用途 |
|----------------|------|----------|-----------|------|
| aiops-image-build | 12 | Git: `k8s/aiops/image-build` | aiops | Docker イメージ自動ビルド CI |
| aiops-alerting | 12 | Git: `k8s/aiops/alerting/prometheusrule.yaml` | monitoring | 予測アラートルール |
| aiops-pushgateway | 12 | Helm: `prometheus-pushgateway` v2.14.0 | monitoring | 異常検知メトリクス受け口 |
| aiops-alert-summarizer | 13 | Git: `k8s/aiops/alert-summarizer/deployment.yaml` | aiops | LLM アラート要約 (Claude API) |
| aiops-anomaly-detection | 13 | Git: `k8s/aiops/anomaly-detection` の `namespace.yaml` + `cronjob.yaml` | aiops | ログ異常検知 CronJob |
| aiops-auto-remediation | 14 | Git: `k8s/aiops/auto-remediation` (再帰・除外あり) | aiops | 自動修復ワークフローテンプレート + RBAC |
| aiops-auto-remediation-events | 15 | Git: `k8s/aiops/auto-remediation/argo-events` | argo-events | EventSource + Sensor |

**特徴的な設定:**

```yaml
# auto-remediation: サブディレクトリを再帰探索しつつ一部を除外
source:
  path: k8s/aiops/auto-remediation
  directory:
    recurse: true
    exclude: "{kaniko-job.yaml,runner/**,argo-events/**}"
```

- `recurse: true` でサブディレクトリを再帰的に含める
- `exclude` で別 Application が管理するディレクトリ (`argo-events/`) と一時ファイル (`kaniko-job.yaml`) を除外

**ポイント:**
- Wave 12→13→14→15 の4段階で起動: 基盤 (Pushgateway) → 検知 (anomaly-detection) → 修復ロジック → イベント連携
- alerting と pushgateway は `monitoring` namespace にデプロイ (Prometheus が参照するため)
- auto-remediation-events は `argo-events` namespace にデプロイ (Argo Events コントローラーが管理するため)
- 1ファイルに7つの Application を `---` で区切って定義し、関連コンポーネントを一元管理

---

#### backstage.yaml — 開発者ポータル

| 項目 | 値 |
|------|-----|
| Wave | 16 |
| Helm chart | `backstage/backstage` v1.9.6 |
| namespace | `backstage` |
| values | `k8s/backstage/values.yaml` |

```yaml
ignoreDifferences:
  - kind: Secret
    name: backstage-postgresql
    jsonPointers: [/data]    # PostgreSQL パスワードの自動生成
```

**ポイント:**
- サービスカタログ / 開発者���ータル。他のアプリに依存しないため最後 (Wave 16) に起動
- 内蔵 PostgreSQL の Secret パスワードが自動生成されるため ignoreDifferences

---

#### litmus.yaml — カオスエンジニアリング

| 項目 | 値 |
|------|-----|
| Wave | 16 |
| Helm chart | `litmuschaos/litmus` v3.28.0 |
| namespace | `litmus` |
| values | `k8s/litmus/values.yaml` |

```yaml
ignoreDifferences:
  - kind: Secret
    name: litmus-mongodb
    jsonPointers: [/data]
  - group: apps
    kind: StatefulSet
    name: litmus-mongodb
    jqPathExpressions:
      - .spec.volumeClaimTemplates
      - .spec.template.spec
```

**ポイント:**
- カオス実験 (Pod kill、ネットワーク遅延注入等) で自動修復の動作検証に使用
- MongoDB の Secret + StatefulSet に広い ignoreDifferences を設定: MongoDB の PVC テンプレートと Pod spec はコントローラーが動的に更新するため

---

#### crossplane.yaml — 宣言的インフラ管理

| 項目 | 値 |
|------|-----|
| Wave | 16 |
| Helm chart | `crossplane-stable/crossplane` v1.17.1 |
| namespace | `crossplane-system` |
| values | `k8s/crossplane/values.yaml` |

**ポイント:**
- k8s CRD でインフラリソース (VM、DNS レコード等) を宣言的に管理する Terraform 代替
- 他のアプリに依存しないため Wave 16
- シンプルなパターン、SSA 有効
