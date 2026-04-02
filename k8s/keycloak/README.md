# Keycloak — アイデンティティ・アクセス管理 (IAM)

k3s クラスター上に Keycloak を使って SSO (Single Sign-On) / OIDC 認証基盤を構築する。

## 構成

```
Keycloak Server   ← IAM / OIDC プロバイダー (http://keycloak.homelab.local)
PostgreSQL        ← ユーザー・設定の永続化 (内蔵)
```

## 前提条件

- k3s クラスターが稼働していること
- `kubectl` が k3s クラスターに接続できること
- `helm` v3 がインストールされていること

## デプロイ手順

Raspberry Pi 上で実行する。

```bash
cd ~/proxmox-lab/k8s/keycloak

bash install.sh
```

### 手動で実行する場合

```bash
# Helm リポジトリ追加
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

# Namespace 作成
kubectl apply -f namespace.yaml

# デプロイ
helm upgrade --install keycloak \
  bitnami/keycloak \
  --namespace keycloak \
  --version 21.4.4 \
  --values values-keycloak.yaml \
  --timeout 15m \
  --wait
```

## アクセス

### Keycloak UI

| 項目 | 値 |
|------|-----|
| URL | http://keycloak.homelab.local |
| ユーザー | `admin` |
| 初期パスワード | `Keycloak12345` |

> **注意:** 初回ログイン後に必ずパスワードを変更すること。

#### Windows PC からのアクセス設定

管理者権限の PowerShell で以下を実行する。

```powershell
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.21  keycloak.homelab.local"
```

## Realm の作成

各サービスと連携するための Realm を作成する。

1. Keycloak UI にログイン
2. 左上の "master" をクリック → "Create Realm"
3. Realm name: `homelab` → "Create"

## OIDC クライアントの登録

### Grafana との OIDC 統合

1. Keycloak UI → `homelab` realm → Clients → "Create client"
2. 設定:
   - Client ID: `grafana`
   - Client type: OpenID Connect
   - Root URL: `http://grafana.homelab.local`
   - Valid redirect URIs: `http://grafana.homelab.local/login/generic_oauth`
3. Credentials タブで Client secret をメモする

#### Grafana の values.yaml に追記

```yaml
grafana:
  grafana.ini:
    auth.generic_oauth:
      enabled: true
      name: Keycloak
      allow_sign_up: true
      client_id: grafana
      client_secret: <your-client-secret>
      scopes: openid email profile
      auth_url: http://keycloak.homelab.local/realms/homelab/protocol/openid-connect/auth
      token_url: http://keycloak.homelab.local/realms/homelab/protocol/openid-connect/token
      api_url: http://keycloak.homelab.local/realms/homelab/protocol/openid-connect/userinfo
      role_attribute_path: contains(roles[*], 'admin') && 'Admin' || 'Viewer'
```

### ArgoCD との OIDC 統合

1. Keycloak UI → `homelab` realm → Clients → "Create client"
2. 設定:
   - Client ID: `argocd`
   - Client type: OpenID Connect
   - Root URL: `http://argocd.homelab.local`
   - Valid redirect URIs: `http://argocd.homelab.local/auth/callback`
3. Credentials タブで Client secret をメモする

#### ArgoCD の values-argocd.yaml に追記

```yaml
server:
  config:
    oidc.config: |
      name: Keycloak
      issuer: http://keycloak.homelab.local/realms/homelab
      clientID: argocd
      clientSecret: <your-client-secret>
      requestedScopes: ["openid", "profile", "email", "groups"]
```

### Kibana との OIDC 統合

1. Keycloak UI → `homelab` realm → Clients → "Create client"
2. 設定:
   - Client ID: `kibana`
   - Client type: OpenID Connect
   - Root URL: `http://kibana.homelab.local`
   - Valid redirect URIs: `http://kibana.homelab.local/api/security/oidc/callback`
3. Credentials タブで Client secret をメモする

#### Kibana の設定に追記 (kibana.yaml)

```yaml
xpack.security.authc.providers:
  oidc.oidc1:
    order: 0
    realm: keycloak
    description: "Log in with Keycloak"
```

## ユーザーの作成

```
Keycloak UI → homelab realm → Users → "Create new user"
  Username: <ユーザー名>
  Email: <メールアドレス>
  → "Create" → Credentials タブ → パスワード設定
```

## 動作確認

```bash
# Pod の状態確認
kubectl get pods -n keycloak

# NAME                        READY   STATUS    RESTARTS
# keycloak-xxx                1/1     Running   0
# keycloak-postgresql-0       1/1     Running   0

# OIDC エンドポイントの確認
curl http://keycloak.homelab.local/realms/homelab/.well-known/openid-configuration
```

## アンインストール

```bash
helm uninstall keycloak -n keycloak
kubectl delete namespace keycloak
# PVC は自動削除されないため手動で削除
kubectl delete pvc -n keycloak --all
```

## 次のステップ

- Grafana (Phase 1) と OIDC 連携
- ArgoCD (Phase 3-1) と OIDC 連携
- Kibana (Phase 2-1) と OIDC 連携
- Vault (Phase 4-1) と LDAP/OIDC 連携
