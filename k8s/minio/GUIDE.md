# MinIO ガイド

## MinIO とは

MinIO は S3 互換の高性能オブジェクトストレージ。AWS S3 と同じ API を提供するため、
S3 対応ツール (Velero, Grafana Loki, MLflow など) をそのまま利用できる。

## homelab での役割

```
┌─────────────┐   バックアップ   ┌─────────────────────┐
│   Velero    │ ────────────► │  MinIO              │
│ (k8s DR)    │               │  velero-backups/    │
└─────────────┘               └─────────────────────┘
                                    ↑ Longhorn PVC (20Gi)
```

## アーキテクチャ

| コンポーネント | 役割 |
|--------------|------|
| MinIO Server | オブジェクトストレージ本体 (API: 9000番ポート) |
| MinIO Console | Web UI (9001番ポート) |
| PVC (Longhorn) | データ永続化 (20Gi) |

## S3 互換 API

MinIO は AWS S3 と同じエンドポイント仕様を持つ:

```
エンドポイント: http://minio.minio.svc.cluster.local:9000
バケット操作  : s3://bucket-name/path/to/object
```

クラスター内からアクセスする場合は `minio.minio.svc.cluster.local:9000` を S3 URL として指定する。

## Velero との連携

Velero は MinIO を AWS S3 として認識する。接続設定:

```yaml
configuration:
  backupStorageLocation:
    provider: aws
    bucket: velero-backups
    config:
      region: minio          # MinIO では任意の文字列でよい
      s3ForcePathStyle: true # パス形式 (MinIO に必要)
      s3Url: http://minio.minio.svc.cluster.local:9000
```

## ストレージ拡張

`values-minio.yaml` の `persistence.size` を変更して git push するだけ。
Longhorn が動的に PVC を再作成する。

> ⚠️ サイズの縮小はできない。拡大のみ可能。

---

## ファイル構成と各ファイルのコード解説

### ファイル構成一覧

```
k8s/minio/
├── README.md             # デプロイ手順・アクセス情報・トラブルシューティング (運用ドキュメント)
├── GUIDE.md              # MinIO の概念説明・学習用ドキュメント (本ファイル)
└── values-minio.yaml     # Helm チャートのカスタム values (全設定をここで管理)
```

| ファイル | 役割 | 編集タイミング |
|---------|------|--------------|
| `README.md` | 運用手順書。デプロイ方法、アクセス URL、バケット追加手順、トラブルシューティングを記載 | 手順変更時 |
| `GUIDE.md` | 学習用ガイド。MinIO のアーキテクチャや概念を解説 (本ファイル) | 知識整理時 |
| `values-minio.yaml` | Helm の `values.yaml` を上書きするカスタム設定ファイル。MinIO の動作すべてをこのファイルで制御する | 設定変更時 |

> ArgoCD の Application リソース (どの Helm チャートをどの namespace にデプロイするか) は
> `k8s/argocd/root-app.yaml` 等で一元管理されている。`k8s/minio/` ディレクトリには
> Application マニフェストは含まれない。

---

### values-minio.yaml の全設定解説

このファイルは MinIO 公式 Helm チャート (`minio/minio`) に渡すカスタム values。
Helm チャートのデフォルト値を上書きして、homelab 環境に合わせた設定を行う。

以下、セクションごとに詳しく解説する。

#### 1. 認証情報 (rootUser / rootPassword)

```yaml
# -------------------------------------------------------------------
# 認証情報
# -------------------------------------------------------------------
rootUser: admin              # MinIO の管理者ユーザー名
rootPassword: "Minio12345"   # MinIO の管理者パスワード
```

**解説:**

- `rootUser` / `rootPassword` は MinIO の **最高権限アカウント** (AWS でいう root アカウント)
- この認証情報で以下の操作が可能:
  - MinIO Console (Web UI) へのログイン
  - S3 API へのアクセス (AccessKey = rootUser, SecretKey = rootPassword)
  - バケットの作成・削除、ポリシー管理などすべての管理操作
- Velero など他のサービスが MinIO に接続する際もこの認証情報を使う
- homelab 環境のためプレーンテキストで記載しているが、本番環境では Vault や Sealed Secrets で管理すべき

#### 2. 動作モード (mode / replicas)

```yaml
# -------------------------------------------------------------------
# 動作モード
# -------------------------------------------------------------------
mode: standalone   # standalone = シングルノード構成
replicas: 1        # Pod を 1 つだけ起動
```

**解説:**

MinIO には 2 つの動作モードがある:

| モード | 説明 | 必要ノード数 |
|-------|------|------------|
| `standalone` | シングルノード。データ冗長化なし | 1 |
| `distributed` | 複数ノードでイレージャーコーディング。データ冗長化あり | 最低 4 |

- homelab ではリソース節約のため `standalone` を選択
- `standalone` ではデータ冗長化がないため、ディスク障害でデータが失われる可能性がある
- ただし MinIO のデータ自体が Longhorn PVC 上にあるため、Longhorn のレプリカ機能 (通常 2〜3 レプリカ) がディスクレベルの冗長化を担保している
- `replicas: 1` は standalone モードでは必ず 1 にする (distributed モードでは 4 以上)

#### 3. デフォルトバケット (buckets)

```yaml
# -------------------------------------------------------------------
# デフォルトバケット (起動時に自動作成)
# -------------------------------------------------------------------
buckets:
  - name: velero-backups   # バケット名 (S3 のバケットに相当)
    policy: none           # アクセスポリシー (none = 認証必須)
    purge: false           # true にすると Helm upgrade 時にバケット内データを全削除
```

**解説:**

- `buckets` リストに定義したバケットは、MinIO Pod の起動時に **自動作成** される
- Helm チャートが init コンテナ (mc クライアント) を使ってバケットを作成する仕組み
- 各フィールドの意味:

| フィールド | 値 | 説明 |
|-----------|-----|------|
| `name` | `velero-backups` | S3 バケット名。Velero の `backupStorageLocation` で指定する名前と一致させる |
| `policy` | `none` | バケットのアクセスポリシー。`none` = 匿名アクセス不可 (認証が必要)。他に `upload`, `download`, `public` がある |
| `purge` | `false` | `true` にすると Helm upgrade のたびにバケット内のオブジェクトを全削除する。バックアップデータが消えるため **絶対に false** にする |

- 新しいバケットを追加したい場合は、このリストに要素を追加して git push するだけ
- ArgoCD が自動で Helm upgrade を実行し、init コンテナがバケットを作成する

#### 4. Ingress (API エンドポイント)

```yaml
# -------------------------------------------------------------------
# Ingress (API エンドポイント)
# -------------------------------------------------------------------
ingress:
  enabled: true                    # Ingress を作成するか
  ingressClassName: traefik        # 使用する Ingress Controller
  hosts:
    - minio-api.homelab.local      # S3 API のホスト名
```

**解説:**

- この Ingress は MinIO の **S3 API (ポート 9000)** をクラスター外部に公開する
- `minio-api.homelab.local` にアクセスすると、S3 互換 API に到達できる
- `ingressClassName: traefik` は k3s にデフォルトで付属する Traefik Ingress Controller を使用する指定
- クラスター内部からは `minio.minio.svc.cluster.local:9000` で直接アクセスできるため、この Ingress は主にクラスター外部 (Windows 端末など) からの `mc` コマンドや S3 クライアントでの操作用
- Windows の `hosts` ファイルに `192.168.210.25 minio-api.homelab.local` を追記しておく必要がある

#### 5. Ingress (コンソール UI)

```yaml
# -------------------------------------------------------------------
# Ingress (コンソール UI)
# -------------------------------------------------------------------
consoleIngress:
  enabled: true                    # コンソール用 Ingress を作成するか
  ingressClassName: traefik        # 使用する Ingress Controller
  hosts:
    - minio.homelab.local          # コンソール UI のホスト名
```

**解説:**

- この Ingress は MinIO の **Console UI (ポート 9001)** をクラスター外部に公開する
- `minio.homelab.local` にブラウザでアクセスすると、Web ベースの管理画面が表示される
- Console UI では以下の操作が可能:
  - バケットの閲覧・作成・削除
  - オブジェクト (ファイル) のアップロード・ダウンロード・削除
  - ユーザー・ポリシー管理
  - サーバーの監視 (ディスク使用量、ネットワーク等)
- `ingress` (API) と `consoleIngress` (UI) は別の Ingress リソースとして作成される。MinIO は API (9000) と Console (9001) を異なるポートで提供するため、Helm チャートでは 2 つの Ingress を分けて管理する設計になっている

#### 6. 永続化 (persistence)

```yaml
# -------------------------------------------------------------------
# 永続化 (Longhorn)
# -------------------------------------------------------------------
persistence:
  enabled: true          # PersistentVolumeClaim を作成するか
  storageClass: longhorn  # 使用する StorageClass
  size: 20Gi             # ボリュームサイズ
```

**解説:**

- `enabled: true` にすると、MinIO のデータ保存用に PersistentVolumeClaim (PVC) が自動作成される
- `false` にするとデータは Pod のエフェメラルストレージに保存され、Pod 再起動でデータが消失する
- 各フィールドの意味:

| フィールド | 値 | 説明 |
|-----------|-----|------|
| `storageClass` | `longhorn` | Longhorn が提供する分散ストレージを使用。Longhorn はデフォルトで 2 レプリカを持ち、ノード障害時のデータ保護を提供 |
| `size` | `20Gi` | Velero バックアップの保存先として 20GB を確保。バックアップが増えたら拡張可能 |

- Longhorn の StorageClass を使うことで、以下のメリットがある:
  - データが複数ノードにレプリケートされる (standalone モードでもデータ冗長化が得られる)
  - Longhorn UI からボリュームの状態やスナップショットを管理できる
  - 動的プロビジョニングにより PV が自動作成される

#### 7. OIDC 認証 (Keycloak SSO)

```yaml
# -------------------------------------------------------------------
# OIDC 認証 (Keycloak SSO)
# -------------------------------------------------------------------
# Root 認証 (admin/Minio12345) は引き続き有効。
# OIDC ユーザーには consoleAdmin ポリシーが Keycloak の hardcoded claim で付与される。
environment:
  # Keycloak の OpenID Connect ディスカバリ URL
  MINIO_IDENTITY_OPENID_CONFIG_URL: "http://keycloak.homelab.local/realms/homelab/.well-known/openid-configuration"

  # Keycloak で作成した MinIO 用クライアントの ID
  MINIO_IDENTITY_OPENID_CLIENT_ID: "minio"

  # Keycloak クライアントのシークレット (Confidential Client)
  MINIO_IDENTITY_OPENID_CLIENT_SECRET: "minio-keycloak-secret-2026"

  # ログインボタンに表示されるプロバイダ名
  MINIO_IDENTITY_OPENID_DISPLAY_NAME: "Keycloak"

  # Keycloak に要求する OIDC スコープ
  MINIO_IDENTITY_OPENID_SCOPES: "openid,profile,email,groups"

  # MinIO ポリシー名を取得する JWT クレーム名
  MINIO_IDENTITY_OPENID_CLAIM_NAME: "policy"

  # OIDC 認証後のコールバック URL
  MINIO_IDENTITY_OPENID_REDIRECT_URI: "http://minio.homelab.local/oauth_callback"
```

**解説:**

MinIO は OIDC (OpenID Connect) プロバイダと連携して SSO を実現できる。
homelab では Keycloak を OIDC プロバイダとして使用している。

**認証フローの流れ:**

```
1. ユーザーが MinIO Console で「Login with SSO」をクリック
2. Keycloak のログイン画面にリダイレクト
3. Keycloak で認証 (admin / Keycloak12345)
4. Keycloak が JWT トークンを発行し REDIRECT_URI にコールバック
5. MinIO が JWT の "policy" クレームを読み取り、対応するポリシーを適用
6. ユーザーが MinIO Console にログイン完了
```

**各環境変数の詳細:**

| 環境変数 | 役割 |
|---------|------|
| `CONFIG_URL` | Keycloak の OIDC ディスカバリエンドポイント。MinIO はここから認証・トークンエンドポイント等を自動取得する |
| `CLIENT_ID` | Keycloak の「Clients」で作成した MinIO 用クライアントの ID。Keycloak 側で事前に `minio` クライアントを作成しておく必要がある |
| `CLIENT_SECRET` | Keycloak クライアントのシークレット。Confidential タイプのクライアントで必要 |
| `DISPLAY_NAME` | Console のログインページに「Login with Keycloak」と表示される名前 |
| `SCOPES` | Keycloak に要求する情報の範囲。`groups` を含めることでグループベースのポリシー割り当てが可能 |
| `CLAIM_NAME` | JWT トークン内のどのクレーム (フィールド) を MinIO のポリシー名として解釈するか。`policy` を指定すると、Keycloak 側で `policy: consoleAdmin` というクレームを hardcoded mapper で追加することで、OIDC ユーザーに管理者権限を付与できる |
| `REDIRECT_URI` | OIDC 認証完了後に Keycloak がユーザーをリダイレクトする URL。MinIO Console のドメインに `/oauth_callback` を付けたもの |

> `environment` ブロックは Helm チャートが MinIO Pod の環境変数として注入する。
> MinIO は起動時にこれらの `MINIO_IDENTITY_OPENID_*` 環境変数を読み取り、OIDC 連携を有効化する。

#### 8. リソース制限 (resources)

```yaml
# -------------------------------------------------------------------
# リソース制限
# -------------------------------------------------------------------
resources:
  requests:
    cpu: 100m        # 最低保証 CPU (0.1 コア)
    memory: 256Mi    # 最低保証メモリ (256MB)
  limits:
    cpu: 500m        # CPU 上限 (0.5 コア)
    memory: 512Mi    # メモリ上限 (512MB)
```

**解説:**

Kubernetes のリソース管理における `requests` と `limits` の使い分け:

| フィールド | 意味 | 超過時の挙動 |
|-----------|------|------------|
| `requests.cpu` | スケジューラがノードに Pod を配置する際の最低保証 CPU | - |
| `requests.memory` | スケジューラがノードに Pod を配置する際の最低保証メモリ | - |
| `limits.cpu` | Pod が使用できる CPU の上限 | スロットリング (速度制限) される |
| `limits.memory` | Pod が使用できるメモリの上限 | OOMKilled (強制終了) される |

- `100m` は 0.1 CPU コアを意味する (1000m = 1 コア)
- `256Mi` は 256 メビバイト (約 268MB)
- MinIO standalone モードは比較的軽量なので、この設定で homelab では十分
- Velero のバックアップ実行中は一時的に CPU / メモリ使用量が上がるが、`limits` 内に収まる範囲
