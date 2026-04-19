# Keycloak — アイデンティティ・アクセス管理 (IAM)

k3s クラスター上に Keycloak を使って SSO (Single Sign-On) / OIDC 認証基盤を構築する。

## 構成

```
Keycloak Server   ← IAM / OIDC プロバイダー (http://keycloak.homelab.local)
PostgreSQL        ← ユーザー・設定の永続化 (内蔵)
```

## SSO 連携状況

| サービス | 状態 | 認証方式 | 既存ローカル認証 |
|---------|------|---------|----------------|
| ArgoCD | 設定済み | OIDC (Keycloak homelab realm) | admin / Argocd12345 |
| Grafana | 設定済み | Generic OAuth (Keycloak homelab realm) | admin / values.yaml |
| Harbor | 設定済み | OIDC (Keycloak homelab realm) | admin / Harbor12345 |
| Vault | 設定済み | OIDC (Keycloak homelab realm) | userpass: admin / Vault12345 |
| MinIO | 設定済み | OIDC (Keycloak homelab realm) | admin / Minio12345 |
| Kibana | 設定済み | oauth2-proxy (Keycloak homelab realm) | — (認証なし時は直接アクセス) |

### Keycloak 設定内容

| 項目 | 値 |
|------|-----|
| Realm | `homelab` |
| 管理グループ | `homelab-admins` |
| 管理ユーザー | `admin` / `Keycloak12345` |

### OIDC クライアント一覧

| クライアント ID | Redirect URI | Client Secret |
|--------------|-------------|------|
| `argocd` | `http://argocd.homelab.local/auth/callback` | `argocd-keycloak-secret-2026` |
| `grafana` | `http://grafana.homelab.local/login/generic_oauth` | `grafana-keycloak-secret-2026` |
| `harbor` | `http://harbor.homelab.local/c/oidc/callback` | `harbor-keycloak-secret-2026` |
| `vault` | `http://vault.homelab.local/ui/vault/auth/oidc/oidc/callback` | `vault-keycloak-secret-2026` |
| `minio` | `http://minio.homelab.local/oauth_callback` | `minio-keycloak-secret-2026` |
| `kibana` | `http://kibana.homelab.local/oauth2/callback` | `kibana-keycloak-secret-2026` |

> MinIO クライアントには `consoleAdmin` ポリシーを返す hardcoded claim mapper が設定されている。

---

## 前提条件

- kubectl が k3s クラスターに接続できること
- Harbor が起動済みであること (`setup.sh` の STEP 7 で Harbor API を呼ぶため)
- `k8s/coredns-custom.yaml` が存在すること

---

## デプロイ手順

Raspberry Pi 上で実行する。

### 1. Keycloak デプロイ

```bash
cd ~/proxmox-lab/k8s/keycloak
bash install.sh
```

### 2. 初期セットアップ (初回デプロイ時のみ)

```bash
bash setup.sh
```

`setup.sh` が以下を自動実行する:

| STEP | 内容 |
|------|------|
| 1 | CoreDNS カスタム設定を適用 (Pod 間で `homelab.local` を解決可能にする) |
| 2 | Keycloak Pod 起動待ち |
| 3 | kcadm ログイン |
| 4 | `homelab` realm 作成 |
| 5 | OIDC クライアント作成 (argocd / grafana / harbor / vault / minio / kibana) |
| 6 | `homelab-admins` グループ・管理ユーザー作成 |
| 7 | groups mapper 追加 (全 6 クライアント) |
| 8 | MinIO policy mapper 追加 (consoleAdmin hardcoded claim) |
| 9 | Harbor OIDC 設定 (API 呼び出し) |
| 10 | Vault OIDC 設定 (unsealed 時のみ) |

---

## ログイン方法

### ArgoCD SSO

1. `http://argocd.homelab.local` を開く
2. **Log in via Keycloak** をクリック
3. `admin` / `Keycloak12345` でログイン

> ローカル admin ログインは引き続き利用可能。

### Grafana SSO

1. `http://grafana.homelab.local` を開く
2. **Sign in with Keycloak** をクリック
3. `admin` / `Keycloak12345` でログイン

### Harbor SSO

1. `http://harbor.homelab.local` を開く
2. **Login via OIDC Provider** をクリック
3. `admin` / `Keycloak12345` でログイン

> Harbor のローカル admin は引き続き使用可能 (auth_mode が oidc_auth でも admin は local 認証)。

### Vault SSO

1. `http://vault.homelab.local` を開く
2. Method: **OIDC** を選択
3. **Sign In** をクリック → Keycloak にリダイレクト
4. `admin` / `Keycloak12345` でログイン

> userpass 認証 (admin / Vault12345) も引き続き利用可能。

### MinIO SSO

1. `http://minio.homelab.local` を開く
2. **Login with SSO** をクリック → Keycloak にリダイレクト
3. `admin` / `Keycloak12345` でログイン

> Root 認証 (admin / Minio12345) も引き続き利用可能。

### Kibana SSO

1. `http://kibana.homelab.local` を開く
2. 自動的に Keycloak ログインページにリダイレクトされる
3. `admin` / `Keycloak12345` でログイン

> oauth2-proxy 経由で認証。Kibana 自体には認証機能がないため、Traefik の forwardAuth ミドルウェアで保護する。

---

## アクセス情報

| 項目 | 値 |
|------|-----|
| URL | http://keycloak.homelab.local |
| ユーザー (master realm) | `admin` / `Keycloak12345` |
| ユーザー (homelab realm) | `admin` / `Keycloak12345` |

---

## 動作確認

```bash
# Pod の状態確認
kubectl get pods -n keycloak

# OIDC エンドポイントの確認 (クラスター内 Pod から)
kubectl run -it --rm test --image=alpine --restart=Never -- \
  wget -qO- http://keycloak.homelab.local/realms/homelab/.well-known/openid-configuration
```

---

## アンインストール

```bash
helm uninstall keycloak -n keycloak
kubectl delete namespace keycloak
kubectl delete pvc -n keycloak --all
```
