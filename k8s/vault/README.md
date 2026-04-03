# Vault — シークレット管理

k3s クラスター上に HashiCorp Vault を使ってシークレット管理基盤を構築する。

## 構成

```
Vault Server (Standalone)  ← シークレット管理 (http://vault.homelab.local)
Vault Agent Injector       ← Pod へのシークレット自動注入
```

## 前提条件

- k3s クラスターが稼働していること
- `kubectl` が k3s クラスターに接続できること
- `helm` v3 がインストールされていること

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

## 基本的な使い方

### Vault とは

パスワード・APIキー・証明書などの機密情報 (シークレット) を安全に保管するツール。
アプリの設定ファイルにパスワードを直書きする代わりに、Vault から取得する運用にできる。

```
アプリが Vault にシークレットを要求
    ↓
Vault が認証・認可を確認
    ↓
シークレットを返す (設定ファイルに平文で書く必要がない)
```

### STEP 1: ログイン

1. `http://vault.homelab.local` を開く
2. Method: **Token** を選択
3. Token: 初期化時に発行した Root Token (`hvs.` で始まる文字列) を入力
4. **Sign In** をクリック

> **注意:** vault-0 Pod が再起動するたびに Sealed 状態に戻る。その都度アンシールが必要 (下記参照)。

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

### Pod 再起動後のアンシール手順

vault-0 が再起動した場合は以下の 3 コマンドを実行する:

```bash
kubectl exec -n vault vault-0 -- vault operator unseal <Unseal Key 1>
kubectl exec -n vault vault-0 -- vault operator unseal <Unseal Key 2>
kubectl exec -n vault vault-0 -- vault operator unseal <Unseal Key 3>
```

---

## 初期化 (初回デプロイ時のみ)

### STEP 1: Vault の初期化

```bash
kubectl exec -n vault vault-0 -- vault operator init \
  -key-shares=5 \
  -key-threshold=3
```

**出力例:**

```
Unseal Key 1: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
Unseal Key 2: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
Unseal Key 3: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
Unseal Key 4: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
Unseal Key 5: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

Initial Root Token: hvs.xxxxxxxxxxxxxxxxxxxxxxxxxx
```

> **重要:** Unseal Key と Root Token は必ず安全な場所に保管すること。再表示は不可能。

### STEP 2: Vault のアンシール

Vault を使用可能にするために 3 つ以上の Unseal Key でアンシールする。

```bash
kubectl exec -n vault vault-0 -- vault operator unseal <Unseal Key 1>
kubectl exec -n vault vault-0 -- vault operator unseal <Unseal Key 2>
kubectl exec -n vault vault-0 -- vault operator unseal <Unseal Key 3>
```

### STEP 3: ステータス確認

```bash
kubectl exec -n vault vault-0 -- vault status
```

`Sealed: false` になっていれば正常。

> **注意:** k3s Pod が再起動するたびに Vault はシールされる。その都度アンシールが必要。

### STEP 4: Root Token でログイン

```bash
kubectl exec -n vault vault-0 -- vault login <Initial Root Token>
```

## アクセス

### Vault UI

| 項目 | 値 |
|------|-----|
| URL | http://vault.homelab.local |
| 認証方法 | Token |
| Root Token | 初期化時に取得した `Initial Root Token` |

#### Windows PC からのアクセス設定

管理者権限の PowerShell で以下を実行する。

```powershell
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.21  vault.homelab.local"
```

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

## 動作確認

```bash
# Pod の状態確認
kubectl get pods -n vault

# NAME               READY   STATUS    RESTARTS
# vault-0            1/1     Running   0  ← アンシール後
# vault-agent-injector-xxx  1/1  Running  0

# Vault のステータス確認
kubectl exec -n vault vault-0 -- vault status
```

## アンインストール

```bash
helm uninstall vault -n vault
kubectl delete namespace vault
# PVC は自動削除されないため手動で削除
kubectl delete pvc -n vault --all
```

## 次のステップ

- Keycloak (Phase 4-2) の接続情報を Vault で管理
- ArgoCD (Phase 3-1) の Git リポジトリ認証情報を Vault に移行
- Vault Agent Injector を使って Pod へシークレットを自動注入
