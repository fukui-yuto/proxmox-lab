# Vault 詳細ガイド — HashiCorp Vault シークレット管理

## このツールが解決する問題

アプリの設定ファイルにパスワードや API キーを直書きしていると以下の問題が起きる:

```yaml
# 問題のある設定例
env:
  - name: DB_PASSWORD
    value: "mypassword123"   # ← Git に入ってしまう
  - name: API_KEY
    value: "sk-abc123..."    # ← 漏洩リスク
```

Vault はシークレット (機密情報) を安全に管理し、アプリから安全に取得できる仕組みを提供する。

```
良い設計:
アプリ → Vault に認証 → シークレットを取得 → 使う
パスワードは Git にも設定ファイルにも書かない
```

---

## Vault の基本概念

### Seal / Unseal (封印 / 解封)

Vault の最も重要な概念。**Vault は起動時に必ず Sealed (封印) 状態から始まる**。
Sealed 状態ではシークレットにアクセスできない。使うには Unseal Key で解封する必要がある。

```
起動直後: Sealed (封印) → シークレットにアクセス不可
          ↓  Unseal Key を入力 (3/5 など閾値分)
使用中: Unsealed (解封) → シークレットにアクセス可能
          ↓  Pod 再起動
起動直後: Sealed (封印) に戻る  ← 毎回アンシールが必要
```

**なぜこの仕組みがあるのか:**
- サーバーが盗まれてもシークレットが自動的に読めない
- Unseal Key を複数に分散して保管することで、1人では復号できない設計にできる

### Unseal Key の仕組み (Shamir's Secret Sharing)

初期化時に `key-shares=5, key-threshold=3` と指定すると:

- 5つの Unseal Key が生成される
- そのうち 3つあれば解封できる (5つ全て不要)
- 1〜2つが漏洩しても安全

```
Key 1 → Alice が保管
Key 2 → Bob が保管
Key 3 → Carol が保管
Key 4 → Dave が保管
Key 5 → Eve が保管

解封には 3人の Key が必要 → 1人の意志では解封できない
```

---

## Secret Engine (シークレットエンジン)

Vault は様々な種類のシークレットを管理できる。用途に応じてエンジンを使い分ける。

| エンジン | 用途 | 例 |
|---------|------|----|
| **KV (Key-Value)** | 静的なシークレット保存 | パスワード、API キー |
| **PKI** | 証明書の発行・管理 | TLS 証明書の自動発行 |
| **Database** | DB の動的認証情報生成 | 使い捨て DB パスワード |
| **AWS** | AWS 一時認証情報生成 | 期限付き IAM クレデンシャル |
| **SSH** | SSH 証明書の発行 | 期限付き SSH アクセス |

このラボでは **KV v2** を使う (最もシンプルなシークレット保存)。

### KV v2 の特徴

- **バージョン管理:** シークレットを更新しても過去のバージョンを参照できる
- **ソフトデリート:** 削除してもバージョン履歴が残る (完全削除は別コマンド)

---

## 認証メソッド (Auth Method)

Vault へのアクセスには認証が必要。様々な認証方法をサポートしている。

| 認証方法 | 用途 |
|---------|------|
| **Token** | 最もシンプル。Root Token や発行した Token |
| **Kubernetes** | k8s の ServiceAccount で認証 → Pod が自動認証できる |
| **LDAP** | Active Directory / LDAP ユーザー認証 |
| **GitHub** | GitHub トークンで認証 |
| **AppRole** | アプリ向けの認証 (CI/CD 等) |

### Kubernetes 認証の仕組み

```
Pod (ServiceAccount: myapp) → Vault に認証リクエスト
Vault → k8s API に「この ServiceAccount は本物か」確認
k8s → 確認 OK
Vault → Pod に Vault Token を発行
Pod → Vault Token を使ってシークレット取得
```

これにより Pod はパスワードなしで Vault に認証できる。

---

## ポリシー (Policy)

「誰が」「何に」アクセスできるかを定義する ACL ルール。

```hcl
# myapp-policy の例
path "secret/data/myapp/*" {
  capabilities = ["read"]        # 読み取りのみ
}

path "secret/data/admin/*" {
  capabilities = ["create", "read", "update", "delete", "list"]  # フル権限
}
```

| capability | 内容 |
|-----------|------|
| `create` | 新規作成 |
| `read` | 読み取り |
| `update` | 更新 |
| `delete` | 削除 |
| `list` | 一覧取得 |

---

## Vault Agent Injector

**Pod にシークレットを自動注入するサイドカー**。
Pod に `vault.hashicorp.com/agent-inject` アノテーションを付けるだけで
シークレットをファイルとして `/vault/secrets/` に自動配置する。

```yaml
# アノテーションを付けるだけでシークレットが注入される
apiVersion: v1
kind: Pod
metadata:
  annotations:
    vault.hashicorp.com/agent-inject: "true"
    vault.hashicorp.com/role: "myapp"
    vault.hashicorp.com/agent-inject-secret-config: "secret/data/myapp/config"
spec:
  containers:
    - name: myapp
      image: myapp:1.0.0
      # /vault/secrets/config にシークレットが自動配置される
```

```
Pod 起動時:
┌─────────────────────────────┐
│  Init Container (Vault Agent) │ → Vault に認証 → シークレット取得
│  /vault/secrets/config       │ ← ファイルとして書き込み
└───────���────────────���────────┘
         ↓
┌─────────────────���───────────┐
│  myapp コンテナ              │
│  /vault/secrets/config を読む │
└─────────────────��───────────┘
```

---

## このラボでの初期セットアップ手順

### 1. 初期化 (初回のみ)

```bash
kubectl exec -n vault vault-0 -- vault operator init \
  -key-shares=5 \
  -key-threshold=3
```

出力される以下を **必ず安全な場所に保存する** (再表示不可):
- `Unseal Key 1` 〜 `Unseal Key 5`
- `Initial Root Token`

### 2. アンシール (Pod 再起動のたびに必要)

```bash
kubectl exec -n vault vault-0 -- vault operator unseal <Unseal Key 1>
kubectl exec -n vault vault-0 -- vault operator unseal <Unseal Key 2>
kubectl exec -n vault vault-0 -- vault operator unseal <Unseal Key 3>
# Sealed: false になれば OK
```

### 3. シークレットの作成

```bash
# KV エンジンを有効化
kubectl exec -n vault vault-0 -- vault secrets enable -path=secret kv-v2

# シークレットを書き込む
kubectl exec -n vault vault-0 -- vault kv put secret/myapp \
  db_password="s3cur3p@ss" \
  api_key="sk-abc123"

# シークレットを読み取る
kubectl exec -n vault vault-0 -- vault kv get secret/myapp
```

---

## よく使うコマンド

```bash
# Vault の状態確認 (Sealed/Unsealed)
kubectl exec -n vault vault-0 -- vault status

# シークレット一覧
kubectl exec -n vault vault-0 -- vault kv list secret/

# シークレットのバージョン確認
kubectl exec -n vault vault-0 -- vault kv metadata get secret/myapp

# 登録されている認証メソッド一覧
kubectl exec -n vault vault-0 -- vault auth list

# 登録されているシークレットエンジン一覧
kubectl exec -n vault vault-0 -- vault secrets list

# ポリシー一覧
kubectl exec -n vault vault-0 -- vault policy list
```

---

## トラブルシューティング

### vault-0 が Running だが 0/1 READY

Sealed 状態。アンシールが必要。

```bash
kubectl exec -n vault vault-0 -- vault status | grep Sealed
# Sealed: true → アンシールが必要
```

### シークレットの読み取りが Permission denied

認証 Token にポリシーが付与されていない。

```bash
# 現在の Token の情報確認
kubectl exec -n vault vault-0 -- vault token lookup

# Token のポリシーが myapp-policy を含んでいるか確認
# policies: [default, myapp-policy]
```
