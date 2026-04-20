# Backstage ガイド

## 概要

Backstage は Spotify が開発したオープンソースの開発者ポータル。
全サービスのドキュメント・CI/CD・ログ・依存関係へのワンストップアクセスを提供する「ソフトウェアカタログ」を構築できる。

---

## 主要機能

| 機能 | 説明 |
|------|------|
| Software Catalog | 全サービス・API・インフラの一覧と依存関係可視化 |
| TechDocs | コードと同居する Markdown ドキュメントの自動ホスティング |
| Kubernetes Plugin | クラスター内の Pod・Deployment 状態をサービス単位で表示 |
| ArgoCD Plugin | ArgoCD の Application 状態を Backstage から閲覧 |
| Scaffolder | テンプレートからサービス・リポジトリを自動生成 |

---

## カタログ登録 (catalog-info.yaml)

各サービスのリポジトリルートに `catalog-info.yaml` を置くことでカタログに登録される。

```yaml
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: my-service
  description: My homelab service
  annotations:
    argocd/app-name: my-service
    backstage.io/kubernetes-id: my-service
    backstage.io/techdocs-ref: dir:.
  tags:
    - go
    - api
spec:
  type: service
  lifecycle: production
  owner: user:fukui-yuto
  system: homelab
  providesApis:
    - my-service-api
```

---

## homelab での活用シナリオ

1. **全サービスの一覧化**: ArgoCD に登録済みの各アプリを Backstage カタログに登録
2. **Kubernetes 状態の統合**: Pod の状態を Backstage の Component ページで確認
3. **ドキュメント統合**: 各 `k8s/*/README.md` を TechDocs として Backstage でホスティング
4. **Scaffolder テンプレート**: 新しい k8s アプリのボイラープレートを自動生成

---

## ArgoCD プラグインの設定

`appConfig.argocd` に以下を追加することで ArgoCD と連携できる:

```yaml
argocd:
  baseUrl: http://argocd.homelab.local
  username: admin
  password: Argocd12345
  appLocatorMethods:
    - type: config
      instances:
        - name: homelab
          url: http://argocd.homelab.local
          username: admin
          password: Argocd12345
```

---

## TechDocs の設定

各サービスのディレクトリに `mkdocs.yml` を置くと Backstage が自動的にドキュメントをビルドする。

```yaml
# mkdocs.yml
site_name: My Service
docs_dir: docs
nav:
  - Home: index.md
  - API Reference: api.md
```

---

## ファイル構成と各ファイルのコード解説

### ファイル構成一覧

```
k8s/backstage/
├── values.yaml      # Helm values (Backstage のカスタム設定)
├── README.md        # セットアップ手順・トラブルシューティング
└── GUIDE.md         # 本ファイル (概念説明・カタログ登録・プラグイン)

k8s/argocd/apps/
└── backstage.yaml   # ArgoCD Application (自動デプロイ定義)
```

---

### values.yaml の詳細解説

Backstage Helm chart (`backstage/backstage`) に渡すカスタム値を定義するファイル。
Backstage のアプリケーション設定 (appConfig)、Ingress、PostgreSQL データベースを一括で管理している。

#### backstage.image セクション

```yaml
backstage:
  image:
    registry: ghcr.io
    repository: backstage/backstage
    tag: latest
    pullPolicy: IfNotPresent
```

- **`registry: ghcr.io`**: Backstage の公式コンテナイメージは GitHub Container Registry でホストされている。
- **`tag: latest`**: 常に最新版を使用する設定。本番では固定タグが推奨だが、homelab では最新機能を試すため `latest` を採用。
- **`pullPolicy: IfNotPresent`**: ローカルにイメージが存在すれば再ダウンロードしない。帯域の節約になる。

#### backstage.appConfig.app セクション

```yaml
  appConfig:
    app:
      title: Homelab Developer Portal
      baseUrl: http://backstage.homelab.local
```

- **`title`**: Backstage UI の左上に表示されるポータル名。任意の名前を設定できる。
- **`baseUrl`**: フロントエンドがブラウザに公開される URL。Ingress のホスト名と一致させる必要がある。

#### backstage.appConfig.backend セクション

```yaml
    backend:
      baseUrl: http://backstage.homelab.local
      listen:
        port: 7007
      cors:
        origin: http://backstage.homelab.local
      database:
        client: pg
        connection:
          host: ${POSTGRES_HOST}
          port: ${POSTGRES_PORT}
          user: ${POSTGRES_USER}
          password: ${POSTGRES_PASSWORD}
```

- **`baseUrl`**: バックエンド API の公開 URL。フロントエンドと同じホスト名でルーティングされる。
- **`listen.port: 7007`**: バックエンドプロセスがコンテナ内でリッスンするポート番号。Backstage のデフォルト。
- **`cors.origin`**: CORS (Cross-Origin Resource Sharing) で許可するオリジン。フロントエンドと同一オリジンのため、ブラウザからの API 呼び出しが許可される。
- **`database.client: pg`**: データベースクライアントとして PostgreSQL を使用する指定。Backstage は SQLite も対応するが、永続性のため PostgreSQL を採用。
- **`database.connection`**: `${POSTGRES_HOST}` などの環境変数プレースホルダーは、Helm chart が自動的に同一 namespace 内の PostgreSQL サービスの接続情報を注入する。

#### backstage.appConfig.catalog セクション

```yaml
    catalog:
      rules:
        - allow:
            - Component
            - API
            - Resource
            - System
            - Domain
            - Location
      locations:
        - type: url
          target: https://github.com/fukui-yuto/proxmox-lab/blob/main/backstage-catalog/catalog-info.yaml
```

- **`rules`**: カタログに登録できるエンティティの種類を制限する。ここでは Component (サービス)、API、Resource (インフラ)、System (サービス群)、Domain (ビジネスドメイン)、Location (他のカタログファイルへの参照) を許可している。
- **`locations`**: カタログエンティティの定義ファイルの場所。Backstage は起動時にこの URL から `catalog-info.yaml` を取得し、記載されたサービス情報をカタログに登録する。GitHub の公開リポジトリを参照しているため、リポジトリに Push すればカタログが自動更新される。

#### backstage.appConfig.kubernetes セクション

```yaml
    kubernetes:
      serviceLocatorMethod:
        type: multiTenant
      clusterLocatorMethods:
        - type: config
          clusters:
            - url: https://kubernetes.default.svc
              name: homelab-k3s
              authProvider: serviceAccount
              skipTLSVerify: true
              serviceAccountToken: ${K8S_SERVICE_ACCOUNT_TOKEN}
```

- **`serviceLocatorMethod.type: multiTenant`**: 複数のクラスターやテナントをサポートするサービス発見方式。
- **`clusterLocatorMethods`**: Backstage が接続する Kubernetes クラスターの一覧を定義する。
- **`url: https://kubernetes.default.svc`**: Backstage 自身が動いているクラスター内部の API サーバーアドレス。
- **`name: homelab-k3s`**: Backstage UI でクラスターを識別するための表示名。
- **`authProvider: serviceAccount`**: ServiceAccount トークンで認証する方式。
- **`skipTLSVerify: true`**: k3s の自己署名証明書を使用しているため、TLS 検証をスキップする。
- **`serviceAccountToken`**: 環境変数から注入される ServiceAccount トークン。README.md の手順で生成したトークンを Secret として設定する。

#### ingress セクション

```yaml
ingress:
  enabled: true
  className: traefik
  host: backstage.homelab.local
```

- **`enabled: true`**: Ingress リソースを自動作成し、外部からのアクセスを可能にする。
- **`className: traefik`**: Traefik Ingress Controller を使用する指定。`annotations` ではなく `ingressClassName` フィールドで指定する新しい形式。
- **`host`**: ブラウザからアクセスする際のホスト名。

#### postgresql セクション

```yaml
postgresql:
  enabled: true
  image:
    registry: docker.io
    repository: bitnamilegacy/postgresql
    tag: "17.6.0-debian-12-r4"
  auth:
    username: backstage
    password: Backstage12345
    database: backstage
  primary:
    persistence:
      storageClass: longhorn
      size: 5Gi
    resources:
      requests:
        cpu: 50m
        memory: 128Mi
      limits:
        cpu: 500m
        memory: 256Mi
```

- **`enabled: true`**: Backstage chart に組み込まれた PostgreSQL サブチャートを有効化する。外部 DB を使う場合は `false` にする。
- **`image.repository: bitnamilegacy/postgresql`**: bitnami が Docker Hub から古いイメージを削除したため、`bitnamilegacy` namespace の最新互換イメージを明示指定している。これを指定しないと ImagePullBackOff エラーが発生する。
- **`image.tag: "17.6.0-debian-12-r4"`**: PostgreSQL 17.6 の安定版イメージ。
- **`auth.username / password / database`**: Backstage バックエンドが接続する際の認証情報。chart が自動的に Secret を作成し、Backstage Pod に環境変数として注入する。
- **`primary.persistence.storageClass: longhorn`**: Longhorn 分散ストレージを使用し、ノード障害時もデータを保護する。
- **`primary.persistence.size: 5Gi`**: カタログメタデータの保存には 5GB で十分な容量。
- **`primary.resources`**: PostgreSQL は Backstage のメタデータ保存用途のため、軽量なリソース割り当てにしている。
