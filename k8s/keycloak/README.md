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

## デプロイ手順

Raspberry Pi 上で実行する。

```bash
cd ~/proxmox-lab/k8s/keycloak
bash install.sh
```

デプロイ後、下記「初期セットアップ」を実施する。

---

## 初期セットアップ (初回デプロイ時のみ)

### STEP 1: realm・クライアント・ユーザーを一括作成

kcadm.sh を使って Keycloak に設定を投入する。

```bash
KCADM="/opt/keycloak/bin/kcadm.sh"
POD=$(kubectl get pod -n keycloak -l app.kubernetes.io/name=keycloak -o jsonpath='{.items[0].metadata.name}')

# ログイン
kubectl exec -n keycloak $POD -- $KCADM config credentials \
  --server http://localhost:8080 --realm master \
  --user admin --password Keycloak12345

# realm 作成
kubectl exec -n keycloak $POD -- $KCADM create realms \
  -s realm=homelab -s enabled=true -s displayName="Homelab"

# クライアント作成
kubectl exec -n keycloak $POD -- $KCADM create clients -r homelab \
  -s clientId=argocd -s enabled=true -s protocol=openid-connect \
  -s publicClient=false -s secret=argocd-keycloak-secret-2026 \
  -s 'redirectUris=["http://argocd.homelab.local/auth/callback"]' \
  -s 'webOrigins=["http://argocd.homelab.local"]' -s standardFlowEnabled=true

kubectl exec -n keycloak $POD -- $KCADM create clients -r homelab \
  -s clientId=grafana -s enabled=true -s protocol=openid-connect \
  -s publicClient=false -s secret=grafana-keycloak-secret-2026 \
  -s 'redirectUris=["http://grafana.homelab.local/login/generic_oauth"]' \
  -s 'webOrigins=["http://grafana.homelab.local"]' -s standardFlowEnabled=true

kubectl exec -n keycloak $POD -- $KCADM create clients -r homelab \
  -s clientId=harbor -s enabled=true -s protocol=openid-connect \
  -s publicClient=false -s secret=harbor-keycloak-secret-2026 \
  -s 'redirectUris=["http://harbor.homelab.local/c/oidc/callback"]' \
  -s 'webOrigins=["http://harbor.homelab.local"]' -s standardFlowEnabled=true

# グループ作成
kubectl exec -n keycloak $POD -- $KCADM create groups -r homelab -s name=homelab-admins

# 管理ユーザー作成
kubectl exec -n keycloak $POD -- $KCADM create users -r homelab \
  -s username=admin -s enabled=true -s email=admin@homelab.local
kubectl exec -n keycloak $POD -- $KCADM set-password -r homelab \
  --username admin --new-password Keycloak12345
```

### STEP 2: groups mapper を各クライアントに追加

クライアント ID は `kcadm.sh get clients -r homelab` で確認する。

```bash
# argocd クライアントの ID を取得
CLIENT_ID=$(kubectl exec -n keycloak $POD -- $KCADM get clients -r homelab \
  --fields id,clientId | grep -A1 '"argocd"' | grep id | grep -o '"[a-z0-9-]*"' | tail -1 | tr -d '"')

kubectl exec -n keycloak $POD -- /bin/sh -c \
  "$KCADM create clients/$CLIENT_ID/protocol-mappers/models -r homelab \
  -s name=groups -s protocol=openid-connect \
  -s protocolMapper=oidc-group-membership-mapper \
  -s 'config={\"full.path\":\"false\",\"id.token.claim\":\"true\",\"access.token.claim\":\"true\",\"claim.name\":\"groups\",\"userinfo.token.claim\":\"true\"}'"
# grafana・harbor も同様に実施
```

### STEP 3: Harbor OIDC 設定

```bash
HARBOR_POD=$(kubectl get pod -n harbor -l component=core -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n harbor $HARBOR_POD -- curl -s -X PUT \
  -u admin:Harbor12345 http://localhost:8080/api/v2.0/configurations \
  -H 'Content-Type: application/json' \
  -d '{
    "auth_mode":"oidc_auth",
    "oidc_name":"Keycloak",
    "oidc_endpoint":"http://keycloak.homelab.local/realms/homelab",
    "oidc_client_id":"harbor",
    "oidc_client_secret":"harbor-keycloak-secret-2026",
    "oidc_scope":"openid,profile,email,groups",
    "oidc_verify_cert":false,
    "oidc_auto_onboard":true,
    "oidc_user_claim":"preferred_username",
    "oidc_groups_claim":"groups",
    "oidc_admin_group":"homelab-admins"
  }'
```

### STEP 4: CoreDNS カスタム設定 (クラスター内 DNS)

Pod から `homelab.local` ドメインを解決できるよう CoreDNS に設定する。

```bash
kubectl apply -f k8s/coredns-custom.yaml
kubectl rollout restart deployment/coredns -n kube-system
```

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
