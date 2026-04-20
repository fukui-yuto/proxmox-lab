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

---

## ファイル構成と各ファイルのコード解説

### ファイル構成一覧

| ファイル | 役割 |
|---------|------|
| `namespace.yaml` | Vault 用の Kubernetes Namespace を定義 |
| `values-vault.yaml` | Vault Helm Chart のカスタム設定値 |
| `unseal-cronjob.yaml` | Vault の自動アンシールを行う CronJob |
| `setup-auth.sh` | 初期化後の認証セットアップスクリプト (userpass + OIDC) |

---

### namespace.yaml

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: vault
```

**解説:**

このファイルは Kubernetes の Namespace (名前空間) を作成する。Namespace は k8s 内でリソースをグループ化・分離するための仕組み。

- `apiVersion: v1` — Namespace は Kubernetes のコア API に含まれる最も基本的なリソース
- `kind: Namespace` — このマニフェストが Namespace の定義であることを宣言
- `metadata.name: vault` — 名前空間の名前を `vault` に設定

Vault 関連のすべてのリソース (Pod、Service、Secret、CronJob など) はこの `vault` Namespace 内に配置される。これにより他のアプリケーションとリソースが混在しない。

---

### values-vault.yaml の全設定解説

このファイルは HashiCorp Vault の公式 Helm Chart (`hashicorp/vault`, version 0.28.0) に渡すカスタム設定値。Helm Chart はデフォルト値を持っているが、このファイルで上書きしてラボ環境に最適化している。

#### global.enabled

```yaml
global:
  enabled: true
```

- Helm Chart 全体を有効にするフラグ
- `false` にするとすべてのリソース生成がスキップされる (Chart を一時的に無効化したい場合に使う)
- 通常は `true` のままで問題ない

#### server (Vault サーバー本体の設定)

```yaml
server:
  dev:
    enabled: false
```

- **Dev モードを無効化**: Dev モードは開発用の簡易モードで、Sealed 状態を飛ばして即使える代わりに、データがメモリに保存されるため再起動で全て消失する。本番/ラボ環境では必ず `false` にする

```yaml
  standalone:
    enabled: true
    config: |
      ui = true

      listener "tcp" {
        tls_disable = 1
        address     = "[::]:8200"
        cluster_address = "[::]:8201"
      }

      storage "file" {
        path = "/vault/data"
      }
```

- **Standalone モード**: Vault は単一インスタンスで動作する。HA (High Availability) モードでは複数の Vault Pod がクラスターを構成するが、ラボ環境ではリソース節約のため 1 Pod で十分
- **config ブロック**: Vault サーバーの HCL 設定をインラインで記述している

| 設定 | 意味 |
|------|------|
| `ui = true` | Web UI を有効化 (ブラウザから `vault.homelab.local` でアクセス可能に) |
| `listener "tcp"` | Vault の API リスナー設定 |
| `tls_disable = 1` | TLS を無効化 (ラボ内は HTTP で通信。本番では `0` にして証明書を設定する) |
| `address = "[::]:8200"` | Vault API が待ち受けるポート。IPv4/IPv6 両対応 (`[::]` は全アドレスで Listen) |
| `cluster_address = "[::]:8201"` | HA クラスター間通信用ポート (Standalone でも設定は必要) |
| `storage "file"` | ストレージバックエンド。シークレットデータをファイルシステムに保存する |
| `path = "/vault/data"` | データ保存先ディレクトリ (PVC がマウントされる場所) |

**ストレージバックエンドの選択肢:**
- `file` — ファイルベース (シンプル、Standalone 向け)
- `raft` — Vault 内蔵の分散 KV (HA 向け)
- `consul` — Consul に保存 (外部依存あり)

ラボでは `file` が最もシンプルで適切。

#### resources (リソース制限)

```yaml
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 300m
      memory: 512Mi
```

- **requests**: Pod がスケジュールされる際に最低限確保される CPU/メモリ量
  - `cpu: 100m` — 0.1 CPU コア (1000m = 1 コア)
  - `memory: 256Mi` — 256 MiB のメモリ
- **limits**: Pod が使用できる上限値
  - `cpu: 300m` — 0.3 CPU コア。これを超えるとスロットリングされる
  - `memory: 512Mi` — 512 MiB。これを超えると OOMKilled (強制終了) される

ラボ環境では CPU/メモリが限られているため、控えめな値に設定している。

#### dataStorage (データ永続化)

```yaml
  dataStorage:
    enabled: true
    size: 10Gi
    accessMode: ReadWriteOnce
    storageClass: longhorn
```

- **enabled: true** — PersistentVolumeClaim (PVC) を作成してデータを永続化する。`false` だと Pod 再起動でデータが消える
- **size: 10Gi** — 10 GiB のボリュームを確保。シークレットの量がそこまで多くないラボ環境では十分
- **accessMode: ReadWriteOnce** — 単一ノードからのみ読み書き可能。Standalone モードではこれで問題ない
- **storageClass: longhorn** — Longhorn (分散ストレージ) が PVC のプロビジョニングを担当する。Longhorn はノード間でデータをレプリケートするため、ノード障害時にもデータが保持される

#### auditStorage (監査ログ)

```yaml
  auditStorage:
    enabled: false
```

- Vault の監査ログ (誰がいつ何にアクセスしたか) を保存する PVC
- ラボ環境ではリソース節約のため無効化している

#### ingress (外部アクセス設定)

```yaml
  ingress:
    enabled: true
    ingressClassName: traefik
    hosts:
      - host: vault.homelab.local
        paths:
          - /
    tls: []
```

- **enabled: true** — Ingress リソースを作成し、クラスター外からアクセス可能にする
- **ingressClassName: traefik** — Traefik Ingress Controller を使用 (k3s のデフォルト)
- **hosts** — `vault.homelab.local` でアクセスした時にルーティングされる
- **paths: [/]** — 全パスを Vault Service に転送
- **tls: []** — TLS は未設定 (HTTP のみ)。ラボ内部のため暗号化なしで運用

ブラウザから `http://vault.homelab.local` にアクセスすると、Traefik が Vault Pod にトラフィックを振り分ける。

#### ui (Web UI 設定)

```yaml
ui:
  enabled: true
  serviceType: ClusterIP
```

- **enabled: true** — Vault の Web UI コンポーネントを有効化
- **serviceType: ClusterIP** — Service の種類。ClusterIP はクラスター内部からのみアクセス可能 (外部アクセスは Ingress 経由)

#### injector (Vault Agent Sidecar Injector)

```yaml
injector:
  enabled: true
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      cpu: 100m
      memory: 128Mi
```

- **enabled: true** — Vault Agent Injector を有効化。これは Mutating Webhook として動作し、アノテーション付きの Pod にサイドカーコンテナを自動注入する
- **resources** — Injector 自体のリソース制限。Injector は常駐する Deployment として動くため、軽量に設定している

Injector が有効だと、Pod に `vault.hashicorp.com/agent-inject: "true"` アノテーションを付けるだけで、Vault からシークレットを自動取得するサイドカーが注入される。

#### csi (CSI Provider)

```yaml
csi:
  enabled: false
```

- **CSI (Container Storage Interface) Provider を無効化**
- CSI Provider は Kubernetes の SecretProviderClass を使ってシークレットを Volume としてマウントする仕組み
- Injector と CSI は同じ目的 (Pod にシークレットを渡す) の別アプローチ。ラボでは Injector を使うため CSI は無効化してリソースを節約

---

### unseal-cronjob.yaml の詳細解説

Vault は Pod が再起動すると必ず Sealed (封印) 状態になる。本来は管理者が手動で Unseal Key を入力する必要があるが、ラボ環境では利便性のため CronJob で自動アンシールを実現している。

#### CronJob とは

CronJob は Linux の cron と同じ仕組みで、指定した時間間隔で自動的に Job (一回限りのタスク) を実行する Kubernetes リソース。

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: vault-auto-unseal
  namespace: vault
```

- `batch/v1` API グループの CronJob リソースとして定義
- `vault` Namespace 内に配置される

#### スケジュールと並行制御

```yaml
spec:
  schedule: "* * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
```

| 設定 | 値 | 意味 |
|------|-----|------|
| `schedule` | `"* * * * *"` | **毎分実行** (分 時 日 月 曜日)。1 分ごとに Vault の状態をチェックする |
| `concurrencyPolicy` | `Forbid` | 前回の Job がまだ実行中の場合、新しい Job を作成しない (重複実行防止) |
| `successfulJobsHistoryLimit` | `3` | 成功した Job の履歴を 3 件まで保持 (古いものは自動削除) |
| `failedJobsHistoryLimit` | `3` | 失敗した Job の履歴を 3 件まで保持 |

#### Job テンプレート

```yaml
  jobTemplate:
    spec:
      ttlSecondsAfterFinished: 300
      template:
        spec:
          restartPolicy: OnFailure
```

- **ttlSecondsAfterFinished: 300** — Job 完了後 300 秒 (5 分) で自動削除される。これがないと完了した Job オブジェクトが溜まり続ける
- **restartPolicy: OnFailure** — コンテナが失敗した場合のみ再起動する (成功したら終了)

#### コンテナ設定と環境変数

```yaml
          containers:
            - name: unseal
              image: hashicorp/vault:1.16.1
              env:
                - name: VAULT_ADDR
                  value: "http://vault.vault.svc.cluster.local:8200"
                - name: UNSEAL_KEY_1
                  valueFrom:
                    secretKeyRef:
                      name: vault-unseal-keys
                      key: unseal_key_1
```

- **image: hashicorp/vault:1.16.1** — Vault の公式イメージを使用。`vault` CLI コマンドが含まれている
- **VAULT_ADDR** — Vault サーバーのアドレス。`vault.vault.svc.cluster.local` は k8s 内部 DNS 名で、`vault` Namespace の `vault` Service を指す
- **UNSEAL_KEY_1** — Kubernetes Secret (`vault-unseal-keys`) から Unseal Key を取得して環境変数にセット

**Secret からのキー取得の仕組み:**
```
Kubernetes Secret "vault-unseal-keys"
  └── key: unseal_key_1 → 値: (実際の Unseal Key)
       ↓ secretKeyRef で参照
  環境変数 UNSEAL_KEY_1 に設定される
```

この Secret は Vault 初期化時に手動で作成する必要がある (初期化で得られた Unseal Key を Secret に格納する)。

#### アンシールロジック (command)

```bash
SEALED=$(vault status -format=json 2>/dev/null | grep -o '"sealed":[^,}]*' | grep -o 'true\|false')
if [ "$SEALED" = "true" ]; then
  echo "Vault is sealed. Unsealing..."
  vault operator unseal "$UNSEAL_KEY_1"
  echo "Unseal complete."
else
  echo "Vault is already unsealed. Nothing to do."
fi
```

**処理の流れ:**

1. `vault status -format=json` — Vault の現在の状態を JSON で取得
2. `grep -o '"sealed":[^,}]*'` — JSON から `"sealed":true` または `"sealed":false` 部分を抽出
3. `grep -o 'true\|false'` — `true` か `false` の文字列だけを取り出す
4. **条件分岐:**
   - `SEALED = "true"` → Vault が封印されているので `vault operator unseal` を実行
   - それ以外 → 既にアンシール済みなので何もしない

**なぜ key-threshold=3 なのに 1 つの Key で unseal できるのか:**

このラボでは初期化時に `key-shares=1, key-threshold=1` で設定しているため、1 つの Key だけでアンシールできる。GUIDE.md の解説では分散管理の例として 5/3 を示しているが、自動アンシールの利便性を優先して 1/1 に設定している。

#### リソース制限

```yaml
              resources:
                requests:
                  cpu: 10m
                  memory: 32Mi
                limits:
                  cpu: 50m
                  memory: 64Mi
```

CronJob の Pod は毎分起動して数秒で終了するため、非常に少ないリソースで十分。

---

### setup-auth.sh の流れ解説

このスクリプトは Vault の初期化・アンシール完了後に 1 回だけ実行する。ユーザー認証の設定を行い、Root Token を無効化してセキュリティを高める。

#### 全体の処理フロー

```
1. Vault の状態確認 (Sealed なら中断)
2. Root Token の入力
3. userpass 認証メソッドを有効化
4. admin-policy (全権限ポリシー) を作成
5. admin ユーザーを作成
6. 動作確認 (userpass ログインテスト)
7. OIDC 認証メソッドを有効化 (Keycloak SSO)
8. OIDC ロールを設定
9. Root Token を無効化 (revoke)
```

#### 1. 変数定義とエラーハンドリング

```bash
set -euo pipefail

NAMESPACE="vault"
ADMIN_USER="admin"
ADMIN_PASS="Vault12345"
```

- `set -euo pipefail` — シェルスクリプトの安全設定:
  - `-e`: コマンドがエラーになったら即座にスクリプトを中断
  - `-u`: 未定義の変数を参照したらエラーにする
  - `-o pipefail`: パイプ中のコマンドが失敗した場合もエラーとする

#### 2. Vault 状態確認

```bash
SEALED=$(kubectl exec -n "${NAMESPACE}" vault-0 -- vault status -format=json 2>/dev/null | grep -o '"sealed":[^,}]*' | grep -o 'true\|false')
if [ "${SEALED}" = "true" ]; then
  echo "ERROR: Vault is sealed. Unseal first."
  exit 1
fi
```

アンシール済みでないと認証設定ができないため、事前にチェックして封印状態なら中断する。

#### 3. Root Token の入力と検証

```bash
read -rsp "Root Token を入力してください (hvs.で始まる文字列): " ROOT_TOKEN
```

- `read -rsp` — `-r` (バックスラッシュエスケープ無効), `-s` (入力を非表示=パスワード入力), `-p` (プロンプト表示)
- Root Token は初期化時に一度だけ表示されるもので、スクリプト内にハードコードしない

検証では `vault auth list` を実行し、Token が有効かどうかを確認する。

#### 4. userpass 認証メソッドの有効化

```bash
kubectl exec -n "${NAMESPACE}" vault-0 -- sh -c "VAULT_TOKEN=${ROOT_TOKEN} vault auth enable userpass 2>&1" || echo "(既に有効化済み)"
```

- `vault auth enable userpass` — ユーザー名とパスワードで Vault にログインできる認証方式を有効化
- `|| echo "(既に有効化済み)"` — 既に有効化されている場合はエラーになるが、スクリプトを中断せずメッセージを表示して続行

#### 5. admin-policy の作成

```bash
vault policy write admin-policy - <<'EOF'
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
EOF
```

- `path "*"` — 全パスに対して適用 (ワイルドカード)
- `capabilities` に `sudo` を含む — root 相当の操作 (Token revoke など) も許可
- これにより admin ユーザーは Vault の全機能にアクセスできる

#### 6. admin ユーザーの作成

```bash
vault write auth/userpass/users/${ADMIN_USER} password=${ADMIN_PASS} policies=admin-policy
```

- `auth/userpass/users/admin` パスに書き込むことでユーザーが作成される
- `policies=admin-policy` — ログイン時に admin-policy が自動付与される
- これで `admin` / `Vault12345` でログインできるようになる

#### 7. OIDC 認証メソッドの設定 (Keycloak SSO)

```bash
vault auth enable oidc
```

OIDC (OpenID Connect) 認証を有効化。これにより Keycloak 経由のシングルサインオンが可能になる。

```bash
vault write auth/oidc/config \
  oidc_discovery_url="http://keycloak.homelab.local/realms/homelab" \
  oidc_client_id="vault" \
  oidc_client_secret="vault-keycloak-secret-2026" \
  default_role="keycloak"
```

| 設定 | 意味 |
|------|------|
| `oidc_discovery_url` | Keycloak の OIDC Discovery エンドポイント。Vault はここから認証に必要な情報を自動取得する |
| `oidc_client_id` | Keycloak 側で登録した Vault 用クライアントの ID |
| `oidc_client_secret` | クライアントシークレット (Keycloak と共有する秘密鍵) |
| `default_role` | ログイン時にデフォルトで適用されるロール名 |

```bash
vault write auth/oidc/role/keycloak \
  bound_audiences="vault" \
  allowed_redirect_uris="http://vault.homelab.local/ui/vault/auth/oidc/oidc/callback" \
  allowed_redirect_uris="http://vault.homelab.local/oidc/callback" \
  user_claim="preferred_username" \
  groups_claim="groups" \
  policies="admin-policy" \
  oidc_scopes="openid,profile,email,groups"
```

| 設定 | 意味 |
|------|------|
| `bound_audiences` | トークンの audience (対象サービス) が `vault` であることを検証 |
| `allowed_redirect_uris` | OAuth2 認証フロー後のリダイレクト先 URL (Vault UI のコールバック) |
| `user_claim` | JWT 内のどのフィールドをユーザー名として使うか (`preferred_username` = Keycloak のユーザー名) |
| `groups_claim` | JWT 内のグループ情報フィールド |
| `policies` | OIDC ログイン時に付与されるポリシー |
| `oidc_scopes` | Keycloak に要求するスコープ (ユーザー情報の種類) |

#### 8. Root Token の無効化 (revoke)

```bash
vault token revoke ${ROOT_TOKEN}
```

- Root Token は全権限を持つため、セットアップ完了後は即座に無効化する
- これ以降は `admin` ユーザーまたは Keycloak SSO でのみログイン可能
- **Root Token は再生成できる** (`vault operator generate-root`) ため、完全に失われるわけではない

**セキュリティ上の意義:**
- Root Token が漏洩しても、revoke 済みなら悪用できない
- 日常運用では最小権限の原則に基づき、必要な権限だけを持つユーザーで操作する
