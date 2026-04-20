# シークレット管理の全体像

このドキュメントでは、homelab クラスターにおけるシークレット（秘密情報）の流れと各コンポーネントの役割を説明する。

---

## 1. シークレット管理の全体像

```
[Vault] ─── Vault Agent Injector ──→ [Pod への Secret 注入]
   │
   ├── PKI Engine ──→ [cert-manager] ──→ TLS 証明書自動発行
   │
   ├── KV Engine ──→ DB パスワード / API キー
   │
   └── OIDC Auth ←── [Keycloak] (Vault ログイン認証)

[Keycloak]
   ├── Grafana (OAuth2 / OIDC)
   ├── ArgoCD (OIDC)
   ├── Harbor (OIDC)
   ├── Vault (OIDC)
   ├── Kibana (oauth2-proxy)
   └── MinIO (SSO)
```

Vault がシークレットの中央ストアとして機能し、各アプリケーションは Vault から必要なシークレットを取得する。Keycloak は認証基盤として全サービスに SSO を提供し、Vault 自体のログインにも OIDC 認証を利用する。

---

## 2. 各コンポーネントの役割

| コンポーネント | 役割 | namespace |
|--------------|------|-----------|
| Vault | シークレットの一元管理・動的シークレット生成 | vault |
| cert-manager | TLS 証明書の自動発行・更新 | cert-manager |
| cert-manager-issuers | ClusterIssuer (内部 CA) 定義 | cert-manager |
| Keycloak | SSO 認証基盤・OIDC Provider | keycloak |

### Vault

Vault は KV (Key-Value) エンジンでパスワードや API キーを安全に保管し、PKI エンジンで証明書の発行を行う。Kubernetes Auth Method により、Pod は ServiceAccount を使って Vault に認証し、必要なシークレットを取得できる。

### cert-manager

cert-manager は Certificate リソースを監視し、ClusterIssuer（内部 CA）を使って TLS 証明書を自動発行する。証明書の有効期限が近づくと自動的に更新される。

### Keycloak

Keycloak は OpenID Connect (OIDC) プロバイダーとして動作し、各サービスに統一的なシングルサインオン体験を提供する。ユーザーは一度 Keycloak にログインすれば、全サービスにアクセスできる。

---

## 3. TLS 証明書の流れ

```
cert-manager-issuers (ClusterIssuer: homelab-ca)
        │
        ▼
cert-manager (Certificate リソースを監視)
        │
        ▼
TLS Secret (各 namespace に自動作成)
        │
        ▼
Traefik Ingress (HTTPS 終端)
```

### 証明書発行の流れ

1. `cert-manager-issuers` が内部 CA の ClusterIssuer を定義する
2. 各アプリの Ingress に `cert-manager.io/cluster-issuer` アノテーションを付与する
3. cert-manager が Certificate リソースを検知し、ClusterIssuer に証明書発行を要求する
4. 発行された証明書は Kubernetes Secret (`kubernetes.io/tls` タイプ) として保存される
5. Traefik が Secret を参照し、HTTPS 終端を行う

### 証明書の自動更新

cert-manager は証明書の有効期限を監視し、期限の 2/3 が経過した時点で自動的に更新を行う。これにより、手動での証明書更新作業が不要になる。

---

## 4. 認証フロー (Keycloak SSO)

ユーザーが各サービスにアクセスする際の認証フロー:

```
[ブラウザ] ──→ [サービス (例: Grafana)]
                    │
                    │ 未認証
                    ▼
              [Keycloak] ←── ログイン画面表示
                    │
                    │ 認証成功
                    ▼
              [認証トークン発行 (ID Token / Access Token)]
                    │
                    ▼
              [サービスに戻る (認証済み)]
```

1. ブラウザでサービス（例: Grafana）にアクセスする
2. 未認証の場合、Keycloak の認証エンドポイントにリダイレクトされる
3. Keycloak でログインする（admin / Keycloak12345）
4. 認証トークン（ID Token / Access Token）が発行され、元のサービスに戻る
5. サービスはトークンを検証し、ユーザーのアクセスを許可する

### 各サービスの OIDC 統合方式

| サービス | 統合方式 | 備考 |
|---------|---------|------|
| Grafana | OAuth2 クライアント直接統合 | `auth.generic_oauth` 設定 |
| ArgoCD | OIDC 直接統合 | `oidc.config` で設定 |
| Harbor | OIDC Provider 統合 | 管理画面から設定 |
| Vault | OIDC Auth Method | `vault auth enable oidc` |
| Kibana | oauth2-proxy 経由 | サイドカーとして動作 |
| MinIO | OpenID 統合 | 環境変数で設定 |

---

## 5. シークレットの保存場所一覧

| シークレット | 保存場所 | 参照方法 |
|------------|---------|---------|
| DB パスワード | Vault KV | Vault Agent Injector / External Secrets |
| TLS 証明書 | cert-manager → k8s Secret | Ingress annotation |
| OIDC Client Secret | Vault KV / k8s Secret | 各アプリの values.yaml |
| Keycloak admin パスワード | k8s Secret | Helm values |
| ArgoCD admin パスワード | k8s Secret | argocd-initial-admin-secret |
| Harbor admin パスワード | k8s Secret | Helm values |
| Vault Unseal Key | Vault 内部 | Auto-unseal 設定 |
| MinIO admin パスワード | k8s Secret | Helm values |

### シークレットの参照パターン

**パターン 1: Vault Agent Injector**

Pod にアノテーションを付与することで、Vault Agent がサイドカーとして注入され、Pod の起動時に Vault からシークレットを取得してファイルとしてマウントする。

```
Pod (アノテーション付き)
  └── Vault Agent (サイドカー)
        └── Vault API 呼び出し → シークレット取得
              └── /vault/secrets/ にファイル書き込み
```

**パターン 2: Kubernetes Secret 直接参照**

Helm values でパスワードを指定し、Helm が Kubernetes Secret を作成する。Pod は `secretKeyRef` で環境変数として参照する。

```
Helm values.yaml → k8s Secret → Pod env / volume mount
```

---

## 6. セキュリティ方針

### Git リポジトリの保護

- Git リポジトリにシークレットを直接コミットしない
- パスワードは Helm values のデフォルト値として記載するか、Vault で管理する
- `.gitignore` でシークレット関連ファイルを除外する

### Vault のセキュリティ

- Auto-unseal を設定し、Pod 再起動時に手動 unseal を不要にする
- Kubernetes Auth Method で Pod の ServiceAccount に基づくアクセス制御を行う
- ポリシーで各アプリが参照できるパスを最小限に制限する

### RBAC によるアクセス制御

- namespace ごとに Secret へのアクセスを制限する
- ServiceAccount に最小権限を付与する
- Kyverno ポリシーで Secret の不正な参照を防止する

### ネットワークレベルの保護

- Vault への通信は TLS で暗号化する
- Keycloak への通信も TLS で暗号化する
- NetworkPolicy で namespace 間の通信を制限する

---

## 7. シークレットのライフサイクル

```
[作成] → [保存 (Vault/k8s)] → [配布 (Injector/Secret)] → [利用 (Pod)] → [更新/失効]
     ↑                                                              │
     └──────────────── 自動ローテーション ←─────────────────────────┘
```

### 静的シークレット（パスワード・API キーなど）

1. 管理者が Vault KV に保存する
2. アプリが Vault Agent / External Secrets で取得する
3. 必要に応じて手動でローテーションする

### 動的シークレット（TLS 証明書など）

1. cert-manager が ClusterIssuer に発行を要求する
2. 証明書が自動的に Kubernetes Secret として作成される
3. 有効期限が近づくと cert-manager が自動的に更新する
4. 古い証明書は自動的に破棄される

このように、静的シークレットと動的シークレットで管理方法が異なるが、いずれも手動管理を最小限に抑える設計になっている。
