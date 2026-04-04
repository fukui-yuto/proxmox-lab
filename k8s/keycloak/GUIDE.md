# Keycloak 詳細ガイド — アイデンティティ・アクセス管理 (IAM)

## このツールが解決する問題

ラボに複数のツール (Grafana, ArgoCD, Harbor, Kibana...) があると、それぞれに別のパスワードが必要になる。

```
問題:
  Grafana    → ユーザー/パスワード A
  ArgoCD     → ユーザー/パスワード B
  Harbor     → ユーザー/パスワード C
  Kibana     → ユーザー/パスワード D
  → ツールが増えるほどパスワード管理が大変

解決:
  Keycloak でログイン → 全ツールにアクセス可能 (SSO)
```

---

## 認証の基礎知識

### 認証 (Authentication) と 認可 (Authorization)

| 概念 | 意味 | 例 |
|------|------|----|
| 認証 (AuthN) | 「あなたは誰ですか？」 | ユーザー名/パスワードでの本人確認 |
| 認可 (AuthZ) | 「何ができますか？」 | admin ロールなら全操作可、viewer なら読み取りのみ |

Keycloak は主に **認証** を担当し、認可は各アプリが担当する。

### OAuth2 と OIDC

**OAuth2:** 「アプリに代わって別のサービスにアクセスする権限を委任する」仕組み。

```
例: Grafana が Keycloak に「このユーザーを認証してください」と委任する
ユーザーはパスワードを Grafana に渡さず、Keycloak に渡す
```

**OIDC (OpenID Connect):** OAuth2 の上に「ユーザー情報 (ID) の取得」を追加した仕様。
Keycloak は OIDC プロバイダーとして動作する。

---

## Keycloak の主要概念

### Realm (レルム)

**テナント/環境の区切り**。Realm ごとにユーザー・クライアント・設定を完全に分離できる。

```
Keycloak
├─ master realm (Keycloak 自身の管理用。通常は触らない)
└─ homelab realm (このラボ用)
    ├─ Users: yuto, admin, ...
    ├─ Clients: grafana, argocd, harbor, ...
    └─ Roles: admin, viewer, ...
```

### Client (クライアント)

**Keycloak に認証を委任するアプリ**。Grafana や ArgoCD が Client として登録される。

```
Client 設定の例 (Grafana):
  Client ID: grafana
  Client Type: OpenID Connect
  Root URL: http://grafana.homelab.local
  Valid Redirect URIs: http://grafana.homelab.local/login/generic_oauth
  Client Secret: xxxxxxxxxxxxxxxx  ← Grafana の設定に記載する
```

### Client Secret

Client と Keycloak 間の認証に使うパスワード。
Grafana の設定ファイルに記載し、「このリクエストは本物の Grafana からのものだ」と Keycloak が確認する。

### User (ユーザー)

Keycloak で管理するユーザー。Realm ごとに独立している。

### Role (ロール)

ユーザーの権限グループ。

```
homelab realm のロール例:
  admin  → Grafana で Admin 権限
  viewer → Grafana で Viewer 権限 (読み取りのみ)
```

---

## SSO のログインフロー

Grafana を例にした OIDC ログインの流れ:

```
1. ユーザーが http://grafana.homelab.local にアクセス
        ↓
2. Grafana が「Keycloak でログインしてください」にリダイレクト
   → http://keycloak.homelab.local/realms/homelab/protocol/openid-connect/auth
        ↓
3. ユーザーが Keycloak のログイン画面でユーザー名/パスワードを入力
        ↓
4. Keycloak が認証 OK → Grafana に Authorization Code を渡す
        ↓
5. Grafana が Authorization Code を使って Access Token を取得
        ↓
6. Grafana が Access Token でユーザー情報 (名前、メール、ロール) を取得
        ↓
7. ユーザーが Grafana にログイン完了
```

このフローの間、ユーザーは Grafana にパスワードを渡していない。
Keycloak にだけパスワードを渡している。

---

## JWT トークン

OIDC では認証情報を **JWT (JSON Web Token)** として渡す。
JWT は Base64 でエンコードされた JSON で、3つのパートに分かれる。

```
eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ5dXRvIiwicm9sZXMiOlsiYWRtaW4iXX0.xxxxx
         ↑ Header          ↑ Payload (ユーザー情報)              ↑ Signature
```

**Payload の例 (デコード後):**
```json
{
  "sub": "user-id-123",           ← ユーザーの一意ID
  "preferred_username": "yuto",   ← ユーザー名
  "email": "yuto@example.com",    ← メール
  "roles": ["admin"],             ← ロール
  "exp": 1735689600,              ← 有効期限
  "iss": "http://keycloak.homelab.local/realms/homelab"  ← 発行者
}
```

Grafana はこの JWT を検証し、`roles` フィールドに `admin` があれば Admin として扱う。

---

## Grafana との OIDC 連携設定

`k8s/monitoring/values.yaml` に以下を追加する:

```yaml
grafana:
  grafana.ini:
    auth.generic_oauth:
      enabled: true
      name: Keycloak
      allow_sign_up: true
      client_id: grafana
      client_secret: <Keycloak で生成した Client Secret>
      scopes: openid email profile roles
      auth_url: http://keycloak.homelab.local/realms/homelab/protocol/openid-connect/auth
      token_url: http://keycloak.homelab.local/realms/homelab/protocol/openid-connect/token
      api_url: http://keycloak.homelab.local/realms/homelab/protocol/openid-connect/userinfo
      # Keycloak の roles が admin なら Grafana の Admin に対応
      role_attribute_path: contains(roles[*], 'admin') && 'Admin' || 'Viewer'
```

---

## ArgoCD との OIDC 連携設定

`k8s/argocd/values-argocd.yaml` に以下を追加する:

```yaml
configs:
  cm:
    oidc.config: |
      name: Keycloak
      issuer: http://keycloak.homelab.local/realms/homelab
      clientID: argocd
      clientSecret: <Keycloak で生成した Client Secret>
      requestedScopes: ["openid", "profile", "email", "groups"]
  rbac:
    policy.csv: |
      g, admin, role:admin
      g, viewer, role:readonly
```

---

## Keycloak の OIDC エンドポイント

Keycloak は以下の URL でエンドポイントを自動公開する。
各アプリの OIDC 設定に使用する。

```
# Well-known エンドポイント (全設定が載っている)
http://keycloak.homelab.local/realms/homelab/.well-known/openid-configuration

# 主要エンドポイント
認証:      http://keycloak.homelab.local/realms/homelab/protocol/openid-connect/auth
トークン:  http://keycloak.homelab.local/realms/homelab/protocol/openid-connect/token
ユーザー情報: http://keycloak.homelab.local/realms/homelab/protocol/openid-connect/userinfo
公開鍵:   http://keycloak.homelab.local/realms/homelab/protocol/openid-connect/certs
```

---

## よく使うコマンド

```bash
# Pod の状態確認
kubectl get pods -n keycloak

# Keycloak のログ確認
kubectl logs -n keycloak -l app=keycloak --tail=50

# OIDC エンドポイントの疎通確認
curl http://keycloak.homelab.local/realms/homelab/.well-known/openid-configuration | \
  python3 -m json.tool | head -30

# Keycloak Admin API でユーザー一覧取得 (Token 取得後)
TOKEN=$(curl -s -X POST \
  http://keycloak.homelab.local/realms/master/protocol/openid-connect/token \
  -d 'client_id=admin-cli&username=admin&password=Keycloak12345&grant_type=password' | \
  python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

curl -H "Authorization: Bearer $TOKEN" \
  http://keycloak.homelab.local/admin/realms/homelab/users
```

---

## トラブルシューティング

### Grafana から Keycloak にリダイレクトされない

`grafana.ini` の `auth.generic_oauth.enabled: true` が設定されているか確認する。
Helm upgrade 後に Grafana Pod を再起動:

```bash
kubectl rollout restart deployment -n monitoring kube-prometheus-stack-grafana
```

### `redirect_uri_mismatch` エラー

Keycloak の Client 設定の `Valid Redirect URIs` が一致していない。

```
Keycloak UI → homelab realm → Clients → grafana → Valid redirect URIs
→ http://grafana.homelab.local/* を追加
```

### ログイン後に `access_denied` エラー

ユーザーに必要なロールが割り当てられていない。

```
Keycloak UI → homelab realm → Users → yuto → Role Mappings
→ admin ロールを追加
```
