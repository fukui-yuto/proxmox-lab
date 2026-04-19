# Vault — シークレット管理

k3s クラスター上に HashiCorp Vault を使ってシークレット管理基盤を構築する。

## 構成

| 項目 | 値 |
|------|-----|
| Helm chart | hashicorp/vault |
| バージョン | 0.28.0 |
| Namespace | vault |
| モード | Standalone |
| UI | http://vault.homelab.local |
| 認証方法 (1) | userpass: `admin` / `Vault12345` |
| 認証方法 (2) | OIDC (Keycloak SSO) |

```
Vault Server (Standalone)  ← シークレット管理 (http://vault.homelab.local)
Vault Agent Injector       ← Pod へのシークレット自動注入
```

---

## デプロイ手順

Raspberry Pi 上で実行する。

```bash
cd ~/proxmox-lab/k8s/vault
bash install.sh
```

### 手動で実行する場合

```bash
# Helm リポジトリ追加
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

# Namespace 作成
kubectl apply -f namespace.yaml

# デプロイ
helm upgrade --install vault \
  hashicorp/vault \
  --namespace vault \
  --version 0.28.0 \
  --values values-vault.yaml \
  --timeout 10m \
  --wait
```

---

## 基本的な使い方

### STEP 1: ログイン

**方法 A: userpass 認証**
1. `http://vault.homelab.local` を開く
2. Method: **Username** を選択
3. Username: `admin` / Password: `Vault12345` を入力
4. **Sign In** をクリック

**方法 B: OIDC 認証 (Keycloak SSO)**
1. `http://vault.homelab.local` を開く
2. Method: **OIDC** を選択
3. **Sign In** をクリック → Keycloak にリダイレクト
4. `admin` / `Keycloak12345` でログイン

> **注意:** vault-0 Pod が再起動するたびに Sealed 状態に戻るが、`vault-auto-unseal` CronJob が約 1 分以内に自動アンシールする。

### STEP 2: KV シークレットエンジンを有効化する

シークレットを保存するには、まずストレージエンジンを有効化する。

**UI の場合:**
1. 左メニュー → **Secrets Engines → Enable new engine**
2. **KV** を選択 → Path: `secret` → **Enable Engine**

**CLI の場合:**
```bash
kubectl exec -n vault vault-0 -- vault secrets enable -path=secret kv-v2
```

### STEP 3: シークレットを保存・取得する

**UI の場合:**
1. 左メニュー → **secret → Create secret**
2. Path: `myapp/config`
3. Key / Value を入力 (例: `username` = `admin`, `password` = `s3cr3t`)
4. **Save** をクリック

**CLI の場合:**
```bash
# 書き込み
kubectl exec -n vault vault-0 -- vault kv put secret/myapp/config \
  username="admin" \
  password="s3cr3t"

# 読み取り
kubectl exec -n vault vault-0 -- vault kv get secret/myapp/config
```

### Pod 再起動後のアンシール (自動)

vault-0 が再起動しても、`vault-auto-unseal` CronJob が毎分 sealed 状態を確認して自動的にアンシールする。
通常は手動操作不要。約 1 分以内に `vault-0` が `1/1 Running` になる。

```bash
# CronJob の状態確認
kubectl get cronjob -n vault

# 最新 Job のログ確認
kubectl logs -n vault -l job-name --tail=20
```

**手動でアンシールする場合 (CronJob が機能しない場合のみ):**

```bash
kubectl exec -n vault vault-0 -- vault operator unseal <Unseal Key 1>
```

#### 自動アンシールの仕組み

| リソース | 内容 |
|----------|------|
| `unseal-cronjob.yaml` | 毎分 sealed 状態を確認して unseal する CronJob |
| `vault-unseal-keys` Secret | Unseal Key を保持 (git 管理外・クラスター直接適用) |

> **注意:** `vault-unseal-keys` Secret は git に含まれない。クラスター再構築時は以下で再作成する:
> ```bash
> kubectl create secret generic vault-unseal-keys -n vault \
>   --from-literal=unseal_key_1="<Key1>"
> ```

---

## 初期化 (初回デプロイ時のみ)

> **現在の状態 (2026-04-11 実施済み):** key-shares=1, key-threshold=1 で初期化済み。
> userpass 認証 (admin/Vault12345) を設定済み。Root Token は無効化済み。

### STEP 1: Vault の初期化

ラボ環境では key-shares=1, key-threshold=1 で初期化する (シンプル構成):

```bash
kubectl exec -n vault vault-0 -- vault operator init \
  -key-shares=1 \
  -key-threshold=1 \
  -format=json
```

**出力例:**

```json
{
  "unseal_keys_b64": ["<Unseal Key (base64)>"],
  "root_token": "hvs.xxxxxxxxxxxxxxxxxxxxxxxxxx"
}
```

> **重要:** Unseal Key と Root Token は必ず安全な場所に保管すること。再表示は不可能。

### STEP 2: vault-unseal-keys Secret の作成

```bash
kubectl create secret generic vault-unseal-keys -n vault \
  --from-literal=unseal_key_1="<Unseal Key>"
```

### STEP 3: Vault のアンシール

```bash
kubectl exec -n vault vault-0 -- vault operator unseal <Unseal Key>
```

### STEP 4: 自動アンシール CronJob の適用

```bash
kubectl apply -f unseal-cronjob.yaml
```

### STEP 5: userpass 認証のセットアップ

```bash
bash setup-auth.sh
```

Root Token を入力すると以下が自動実行される:
1. `userpass` 認証メソッドの有効化
2. `admin-policy` (全権限) の作成
3. `admin` ユーザーの作成 (パスワード: `Vault12345`)
4. Root Token の無効化

> **注意:** Root Token はセットアップ完了後に自動で無効化される。
> 以降は admin ユーザーでログインする。
> Root Token が再度必要な場合は `vault operator generate-root` で再生成できる。

### STEP 6: ステータス確認

```bash
kubectl exec -n vault vault-0 -- vault status
```

`Sealed: false` になっていれば正常。

---

## アクセス

### Vault UI

| 項目 | 値 |
|------|-----|
| URL | http://vault.homelab.local |
| userpass 認証 | Username: `admin` / Password: `Vault12345` |
| OIDC 認証 | Method: OIDC → Keycloak (`admin` / `Keycloak12345`) |

---

## シークレットの基本操作

### KV シークレットエンジンの有効化

```bash
kubectl exec -n vault vault-0 -- vault secrets enable -path=secret kv-v2
```

### シークレットの書き込み

```bash
kubectl exec -n vault vault-0 -- vault kv put secret/myapp \
  username="myuser" \
  password="mypassword"
```

### シークレットの読み取り

```bash
kubectl exec -n vault vault-0 -- vault kv get secret/myapp
```

---

## k3s (Kubernetes) との統合

### Kubernetes 認証の有効化

```bash
# Kubernetes 認証メソッドを有効化
kubectl exec -n vault vault-0 -- vault auth enable kubernetes

# Kubernetes クラスターの設定
kubectl exec -n vault vault-0 -- vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443"
```

### ロールの作成

```bash
# Pod がシークレットを読み取るためのロール
kubectl exec -n vault vault-0 -- vault write auth/kubernetes/role/myapp \
  bound_service_account_names=myapp \
  bound_service_account_namespaces=default \
  policies=myapp-policy \
  ttl=1h
```

### ポリシーの作成

```bash
kubectl exec -n vault vault-0 -- vault policy write myapp-policy - << 'EOF'
path "secret/data/myapp" {
  capabilities = ["read"]
}
EOF
```

---

## 動作確認

```bash
# Pod の状態確認
kubectl get pods -n vault

# Vault のステータス確認
kubectl exec -n vault vault-0 -- vault status
```

---

## Root Token の再生成

Root Token が必要になった場合 (新しい認証メソッドの追加など):

```bash
# 1. generate-root を開始
kubectl exec -n vault vault-0 -- vault operator generate-root -init -format=json
# → nonce と otp をメモ

# 2. Unseal Key で認証
echo '<Unseal Key>' | kubectl exec -i -n vault vault-0 -- vault operator generate-root -nonce=<nonce> -format=json -
# → encoded_root_token をメモ

# 3. デコード
kubectl exec -n vault vault-0 -- vault operator generate-root -decode=<encoded_root_token> -otp=<otp>
# → Root Token が表示される

# 4. 使用後は必ず無効化
kubectl exec -n vault vault-0 -- sh -c "VAULT_TOKEN=<root_token> vault token revoke <root_token>"
```

---

## アンインストール

```bash
helm uninstall vault -n vault
kubectl delete namespace vault
# PVC は自動削除されないため手動で削除
kubectl delete pvc -n vault --all
```
