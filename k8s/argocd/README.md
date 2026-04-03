# ArgoCD — GitOps 継続的デリバリー

k3s クラスター上に ArgoCD を使って GitOps ベースの継続的デリバリー基盤を構築する。

## 構成

```
ArgoCD Server     ← GitOps コントローラー (http://argocd.homelab.local)
Repo Server       ← Git リポジトリとの同期
Application Controller ← Kubernetes リソースの reconciliation
Redis             ← キャッシュ
```

## 前提条件

- k3s クラスターが稼働していること
- `kubectl` が k3s クラスターに接続できること
- `helm` v3 がインストールされていること

## デプロイ手順

Raspberry Pi 上で実行する。

```bash
cd ~/proxmox-lab/k8s/argocd

bash install.sh
```

### 手動で実行する場合

```bash
# Helm リポジトリ追加
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

# Namespace 作成
kubectl apply -f namespace.yaml

# デプロイ
helm upgrade --install argocd \
  argo/argo-cd \
  --namespace argocd \
  --version 7.3.4 \
  --values values-argocd.yaml \
  --timeout 10m \
  --wait
```

## アクセス

### ArgoCD UI

| 項目 | 値 |
|------|-----|
| URL | http://argocd.homelab.local |
| ユーザー | `admin` |
| 初期パスワード | 下記コマンドで取得 |

#### 初期パスワードの取得

```bash
kubectl get secret argocd-initial-admin-secret \
  -n argocd \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

> **注意:** 初回ログイン後に UI または CLI でパスワードを変更すること。

#### Windows PC からのアクセス設定

管理者権限の PowerShell で以下を実行する。

```powershell
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.21  argocd.homelab.local"
```

### ArgoCD CLI でのログイン

```bash
# ArgoCD CLI インストール (Linux/Mac)
curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x argocd && sudo mv argocd /usr/local/bin/

# ログイン
ARGOCD_PASSWORD=$(kubectl get secret argocd-initial-admin-secret \
  -n argocd \
  -o jsonpath='{.data.password}' | base64 -d)

argocd login argocd.homelab.local \
  --username admin \
  --password "${ARGOCD_PASSWORD}" \
  --insecure
```

## 基本的な使い方

### ArgoCD とは

Git リポジトリの内容を自動的に Kubernetes に反映するツール。
「Git に push する = クラスターに反映される」という GitOps を実現する。

```
開発者が Git に push
    ↓
ArgoCD が差分を検知
    ↓
クラスターに自動デプロイ
```

### STEP 1: ログイン

1. 初期パスワードを取得する

```bash
kubectl get secret argocd-initial-admin-secret \
  -n argocd \
  -o jsonpath='{.data.password}' | base64 -d && echo
```

2. `http://argocd.homelab.local` を開き、`admin` / 取得したパスワードでログイン
3. ログイン後に **User Info → Update Password** でパスワードを変更する

### STEP 2: Git リポジトリの登録

左メニュー → **Settings → Repositories → Connect Repo**

| 項目 | 値 |
|---|---|
| Connection method | HTTPS |
| Repository URL | `https://github.com/<your-org>/<your-repo>` |
| Username / Password | GitHub の認証情報 (private repo の場合) |

→ **CONNECT** をクリック。`Successful` になれば OK。

### STEP 3: Application の作成 (UI)

左メニュー → **Applications → NEW APP**

| 項目 | 値 |
|---|---|
| Application Name | `my-app` |
| Project | `default` |
| Sync Policy | `Automatic` (自動同期) |
| Repository URL | 登録した Git URL |
| Path | k8s マニフェストが置いてあるディレクトリ (例: `k8s/my-app`) |
| Cluster URL | `https://kubernetes.default.svc` |
| Namespace | `default` |

→ **CREATE** をクリック。

### STEP 4: 同期確認

- アプリカードが **Synced / Healthy** になれば正常にデプロイされている
- **SYNC** ボタンで手動同期、**REFRESH** で Git の最新を取得できる
- Git に変更を push すると自動的にクラスターに反映される

---

## Application の登録例 (CLI)

```bash
# Git リポジトリから Application を作成
argocd app create my-app \
  --repo https://github.com/your-org/your-repo.git \
  --path k8s/my-app \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace default \
  --sync-policy automated
```

または YAML で管理する場合:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/your-repo.git
    targetRevision: HEAD
    path: k8s/my-app
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

## 動作確認

```bash
# Pod の状態確認
kubectl get pods -n argocd

# 全 Pod が Running になっていれば OK
NAME                                               READY   STATUS    RESTARTS
argocd-server-xxx                                  1/1     Running   0
argocd-repo-server-xxx                             1/1     Running   0
argocd-application-controller-0                    1/1     Running   0
argocd-applicationset-controller-xxx               1/1     Running   0
argocd-notifications-controller-xxx                1/1     Running   0
argocd-redis-xxx                                   1/1     Running   0
```

## アンインストール

```bash
helm uninstall argocd -n argocd
kubectl delete namespace argocd
```

## 次のステップ

- Harbor (Phase 3-2) をコンテナレジストリとして設定
- Keycloak (Phase 4-2) と OIDC 連携で SSO を設定
- Kyverno (Phase 6) ポリシーを ArgoCD で GitOps 管理
