# Harbor — コンテナレジストリ

k3s クラスター上に Harbor を使ってプライベートコンテナレジストリを構築する。

## 構成

```
Harbor Core       ← API サーバー・認証 (http://harbor.homelab.local)
Harbor Registry   ← イメージ保存
Harbor Portal     ← Web UI
PostgreSQL        ← メタデータ DB (内蔵)
Redis             ← キャッシュ (内蔵)
Trivy             ← コンテナ脆弱性スキャン
Job Service       ← 非同期ジョブ処理
```

## 前提条件

- k3s クラスターが稼働していること
- `kubectl` が k3s クラスターに接続できること
- `helm` v3 がインストールされていること

## デプロイ手順

Raspberry Pi 上で実行する。

```bash
cd ~/proxmox-lab/k8s/harbor

bash install.sh
```

### 手動で実行する場合

```bash
# Helm リポジトリ追加
helm repo add harbor https://helm.goharbor.io
helm repo update

# Namespace 作成
kubectl apply -f namespace.yaml

# デプロイ
helm upgrade --install harbor \
  harbor/harbor \
  --namespace harbor \
  --version 1.14.2 \
  --values values-harbor.yaml \
  --timeout 15m \
  --wait
```

## アクセス

### Harbor UI

| 項目 | 値 |
|------|-----|
| URL | http://harbor.homelab.local |
| ユーザー | `admin` |
| 初期パスワード | `Harbor12345` |

> **注意:** 初回ログイン後に必ずパスワードを変更すること。

#### Windows PC からのアクセス設定

管理者権限の PowerShell で以下を実行する。

```powershell
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.21  harbor.homelab.local"
```

## 基本的な使い方

### Harbor とは

プライベートなコンテナイメージ置き場。
Docker Hub の代わりに自分のラボ内でイメージを管理できる。
Trivy による脆弱性スキャンも自動で行われる。

```
docker build → docker push → Harbor に保存
                                  ↓
                    k3s が Harbor からイメージを pull
```

### STEP 1: ログインしてプロジェクトを作成

1. `http://harbor.homelab.local` を開き `admin` / `Harbor12345` でログイン
2. 左メニュー → **Projects → NEW PROJECT**
   - Project Name: `homelab`
   - Access Level: Private
   → **OK**
3. ログイン後に右上アイコン → **Change Password** でパスワードを変更する

### STEP 2: ローカル PC から Docker でイメージを push

```bash
# Harbor にログイン
docker login harbor.homelab.local -u admin -p Harbor12345

# 既存イメージにタグを付ける
docker tag nginx:latest harbor.homelab.local/homelab/nginx:latest

# Harbor に push
docker push harbor.homelab.local/homelab/nginx:latest
```

Harbor UI の **Projects → homelab → Repositories** にイメージが表示される。

### STEP 3: k3s クラスターから pull できるようにする

k3s ノードは HTTP (TLS なし) で Harbor にアクセスするため設定が必要。
全ノード (master + worker) で以下を実行する。

```bash
# Terraform の remote-exec で管理しているため、再 apply で反映する
# 手動確認の場合:
sudo cat /etc/rancher/k3s/registries.yaml
```

設定済みの場合は以下の Deployment でテストできる:

```yaml
# test-harbor.yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-harbor
spec:
  containers:
    - name: nginx
      image: harbor.homelab.local/homelab/nginx:latest
```

### STEP 4: 脆弱性スキャン結果の確認

イメージ push 後に Trivy が自動スキャンを実行する。

**Projects → homelab → Repositories → イメージ名 → SCAN** で確認できる。

---

## Docker でのイメージ操作 (コマンドリファレンス)

### Harbor へのログイン

```bash
docker login harbor.homelab.local -u admin -p Harbor12345
```

### イメージのプッシュ

```bash
# イメージにタグを付ける
docker tag my-app:latest harbor.homelab.local/library/my-app:latest

# Harbor にプッシュ
docker push harbor.homelab.local/library/my-app:latest
```

### イメージのプル

```bash
docker pull harbor.homelab.local/library/my-app:latest
```

## k3s への insecure registry 設定

HTTP (TLS なし) で Harbor を使用するため、k3s ノードで insecure registry を設定する。

### 各ノードでの設定手順

全ノード (master + worker x2) で以下を実行する。

```bash
# registries.yaml を作成 (すでに存在する場合は追記)
sudo tee /etc/rancher/k3s/registries.yaml << 'EOF'
mirrors:
  harbor.homelab.local:
    endpoint:
      - "http://harbor.homelab.local"
EOF
```

### k3s の再起動

```bash
# master ノード
sudo systemctl restart k3s

# worker ノード
sudo systemctl restart k3s-agent
```

### 設定確認

```bash
# k3s が insecure registry を認識しているか確認
sudo crictl info | grep -A5 harbor
```

## 動作確認

```bash
# Pod の状態確認
kubectl get pods -n harbor

# 全 Pod が Running になっていれば OK
NAME                                    READY   STATUS    RESTARTS
harbor-core-xxx                         1/1     Running   0
harbor-database-0                       1/1     Running   0
harbor-jobservice-xxx                   1/1     Running   0
harbor-portal-xxx                       1/1     Running   0
harbor-redis-0                          1/1     Running   0
harbor-registry-xxx                     2/2     Running   0
harbor-trivy-0                          1/1     Running   0
```

## アンインストール

```bash
helm uninstall harbor -n harbor
kubectl delete namespace harbor
# PVC は自動削除されないため手動で削除
kubectl delete pvc -n harbor --all
```

## 次のステップ

- ArgoCD (Phase 3-1) のレジストリとして Harbor を設定
- Keycloak (Phase 4-2) と OIDC 連携で SSO を設定
- Kyverno (Phase 6) のポリシーで Harbor のイメージのみ許可する設定を追加
