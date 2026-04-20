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

# 1. ArgoCD をデプロイ
bash install.sh

# 2. Root App (App of Apps) を登録 (初回のみ・一度だけ)
bash register-apps.sh
```

`register-apps.sh` が `root-app.yaml` を apply し、ArgoCD が `k8s/argocd/apps/` 以下の全 Application を自動管理する。
以降は **git push するだけ**で App の追加・変更・削除が反映される。

### App of Apps 構成

```
root (ArgoCD Application)
└── k8s/argocd/apps/ を監視
    ├── kyverno.yaml        → kyverno / kyverno-policies
    ├── longhorn.yaml       → longhorn-prereqs / longhorn
    ├── vault.yaml          → vault
    ├── monitoring.yaml     → monitoring
    ├── harbor.yaml         → harbor
    ├── keycloak.yaml       → keycloak
    ├── logging.yaml        → logging-elasticsearch / fluent-bit / kibana
    ├── tracing.yaml        → tracing-tempo / otel-collector
    ├── argo-workflows.yaml → argo-workflows
    ├── argo-events.yaml    → argo-events
    └── aiops.yaml          → aiops-* (alerting / pushgateway / image-build /
                               alert-summarizer / anomaly-detection /
                               auto-remediation / auto-remediation-events)
```

Sync Wave (0→16) により、依存関係の順序を保って自動デプロイされる。

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
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.24  argocd.homelab.local"
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

## トラブルシューティング

### application-controller が OOMKilled (CrashLoopBackOff) になる

**症状:** `argocd-application-controller-0` が Exit Code 137 (OOMKilled) で繰り返しクラッシュする。

**原因:** 30 以上のアプリを管理する場合、デフォルトの memory limit 1Gi では不足する。

**対処:** `values-argocd.yaml` の `controller.resources.limits.memory` を 2Gi 以上に増やして ArgoCD を再デプロイ:

```yaml
controller:
  resources:
    limits:
      memory: 2Gi  # 1Gi → 2Gi に変更 (2026-04-17)
```

```bash
cd ~/proxmox-lab/k8s/argocd
bash install.sh
```

## アンインストール

```bash
helm uninstall argocd -n argocd
kubectl delete namespace argocd
```

## 常時起動 / オンデマンド起動

| 種別 | Application | 備考 |
|------|-------------|------|
| 常時起動 (automated sync) | kyverno, kyverno-policies | webhook 停止でクラスター操作不能になるため必須 |
| 常時起動 (automated sync) | monitoring | クラスター監視 |
| 常時起動 (automated sync) | logging-elasticsearch, logging-fluent-bit, logging-kibana | ログ収集・閲覧 |
| オンデマンド (手動 sync) | vault | シークレット管理が必要な時 |
| オンデマンド (手動 sync) | harbor | イメージビルド・push 時 |
| オンデマンド (手動 sync) | keycloak | SSO が必要な時 |
| オンデマンド (手動 sync) | tracing-tempo, tracing-otel-collector | トレース調査時 |

### オンデマンドアプリの起動・停止

```bash
# 起動 (例: vault)
argocd app sync vault

# 停止 (例: vault) — リソースを削除して停止
argocd app delete vault --cascade

# または ArgoCD UI から SYNC / DELETE を操作する
```

---

## Sync Wave — 起動順序制御

全アプリを一斉起動すると pve-node01 の e1000e NIC がトラフィックバーストで
Hardware Unit Hang を起こすため、sync wave で起動を段階的に分散している。

| Wave | Application | 備考 |
|------|-------------|------|
| 0 | kyverno / cilium | ポリシーエンジン・eBPF CNI。他リソース作成前に必要 |
| 1 | kyverno-policies | kyverno が Ready になってから適用 |
| 2 | longhorn-prereqs / longhorn | 分散永続ストレージ |
| 3 | vault / minio / cert-manager | シークレット管理・オブジェクトストレージ・証明書 |
| 4 | monitoring / argo-workflows / argo-events / cert-manager-issuers / velero / argo-rollouts / keda / falco | 可観測性・自動修復基盤・バックアップ・セキュリティ |
| 5 | harbor / trivy-operator | コンテナレジストリ・脆弱性スキャン |
| 6 | keycloak | 認証基盤 |
| 7 | logging-elasticsearch | 重い StatefulSet。後半に配置 |
| 8 | logging-fluent-bit | elasticsearch が起動してから |
| 9 | logging-kibana | elasticsearch が起動してから |
| 10 | tracing-tempo | トレーシングバックエンド |
| 11 | tracing-otel-collector | tempo が起動してから |
| 12 | aiops-alerting / aiops-pushgateway / aiops-image-build | AIOps 基盤 |
| 13 | aiops-alert-summarizer / aiops-anomaly-detection | LLM サマリ・異常検知 |
| 14 | aiops-auto-remediation | 自動修復 WorkflowTemplate |
| 15 | aiops-auto-remediation-events | Argo Events トリガー |
| 16 | litmus / backstage / crossplane | カオスエンジニアリング・開発者ポータル・インフラ管理 |

ArgoCD は各 wave の全 Application が Healthy になるまで次の wave に進まない。

## Application 定義ファイル

全 Application の定義は `apps/` ディレクトリに YAML で管理している。

```
apps/
├── kyverno.yaml          # Wave 0-1: kyverno + kyverno-policies
├── longhorn.yaml         # Wave 2:  longhorn-prereqs + longhorn
├── vault.yaml            # Wave 3:  HashiCorp Vault
├── monitoring.yaml       # Wave 4:  kube-prometheus-stack + dashboards
├── harbor.yaml           # Wave 5:  Harbor
├── keycloak.yaml         # Wave 6:  Keycloak
├── logging.yaml          # Wave 7-9: elasticsearch + fluent-bit + kibana
├── tracing.yaml          # Wave 10-11: tempo + otel-collector
├── argo-workflows.yaml   # Wave 4:  Argo Workflows
├── argo-events.yaml      # Wave 4:  Argo Events
└── aiops.yaml            # Wave 12-15: AIOps 全コンポーネント
```

## 次のステップ

- Harbor (Phase 3-2) をコンテナレジストリとして設定
- Keycloak (Phase 4-2) と OIDC 連携で SSO を設定
- Kyverno (Phase 6) ポリシーを ArgoCD で GitOps 管理
