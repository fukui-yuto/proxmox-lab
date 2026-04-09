# Keycloak — アイデンティティ・アクセス管理 (IAM)

k3s クラスター上に Keycloak を使って SSO (Single Sign-On) / OIDC 認証基盤を構築する。

## 構成

```
Keycloak Server   ← IAM / OIDC プロバイダー (http://keycloak.homelab.local)
PostgreSQL        ← ユーザー・設定の永続化 (内蔵)
```

## SSO 連携状況

| サービス | 状態 | 認証方式 |
|---------|------|---------|
| ArgoCD | 設定済み | OIDC (Keycloak homelab realm) |
| Grafana | 設定済み | Generic OAuth (Keycloak homelab realm) |
| Harbor | 設定済み | OIDC (Keycloak homelab realm) |

### Keycloak 設定内容

| 項目 | 値 |
|------|-----|
| Realm | `homelab` |
| 管理グループ | `homelab-admins` |
| 管理ユーザー | `admin` / `Keycloak12345` |

### OIDC クライアント一覧

| クライアント ID | Redirect URI | Client Secret (Vault: `homelab/keycloak-oidc`) |
|--------------|-------------|------|
| `argocd` | `http://argocd.homelab.local/auth/callback` | `argocd_client_secret` |
| `grafana` | `http://grafana.homelab.local/login/generic_oauth` | `grafana_client_secret` |
| `harbor` | `http://harbor.homelab.local/c/oidc/callback` | `harbor_client_secret` |

> クライアントシークレットは Vault の `homelab/keycloak-oidc` に保存済み。

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
| 5 | OIDC クライアント作成 (argocd / grafana / harbor) |
| 6 | `homelab-admins` グループ・管理ユーザー作成 |
| 7 | groups mapper 追加 (argocd / grafana / harbor 全クライアント) |
| 8 | Harbor OIDC 設定 |

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
