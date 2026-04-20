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
