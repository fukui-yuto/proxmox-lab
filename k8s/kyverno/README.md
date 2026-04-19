# Kyverno — Kubernetes ポリシー管理

k3s クラスター上に Kyverno を導入し、Kubernetes リソースへのポリシーを強制する。

## 概要

Kyverno は Kubernetes ネイティブのポリシーエンジン。
YAML でポリシーを定義し、リソースの作成・更新時に自動で検証・変換・生成を行う。

```
kubectl apply / helm install
    ↓
Kyverno Admission Controller  ← ポリシー検証
    ↓ (audit: 警告のみ / enforce: 拒否)
クラスターへ反映
```

---

## デプロイ手順

Raspberry Pi 上で実行する。

```bash
cd ~/proxmox-lab/k8s/kyverno
bash install.sh
```

### 手動で実行する場合

```bash
# Helm リポジトリ追加
helm repo add kyverno https://kyverno.github.io/kyverno
helm repo update

# Kyverno デプロイ
helm upgrade --install kyverno \
  kyverno/kyverno \
  --namespace kyverno \
  --create-namespace \
  --version 3.2.6 \
  --values values-kyverno.yaml \
  --timeout 5m \
  --wait

# ポリシー適用
kubectl apply -f policies/
```

---

## ポリシー一覧

| ファイル | ポリシー名 | 内容 | モード |
|---|---|---|---|
| `require-resource-limits.yaml` | require-resource-limits | 全コンテナに CPU/Memory limits を必須化 | audit |
| `disallow-latest-tag.yaml` | disallow-latest-tag | `latest` タグのイメージを禁止 | audit |
| `require-labels.yaml` | require-labels | `app` ラベルを必須化 | audit |

> **audit モード:** ポリシー違反を検出してもリソースの作成は許可し、レポートに記録する。
> **enforce モード:** ポリシー違反のリソースの作成を拒否する。

---

## 動作確認

```bash
# Pod 確認
kubectl get pods -n kyverno

# ポリシー一覧
kubectl get clusterpolicy

# ポリシーレポート確認 (audit モードで違反を検出したもの)
kubectl get policyreport -A
```

---

## enforce モードへの変更

`policies/` 内の各ファイルの `validationFailureAction` を変更する。

```yaml
# audit → enforce に変更
spec:
  validationFailureAction: enforce
```

変更後に再適用:

```bash
kubectl apply -f policies/
```

---

## ラボ向け安定性設定

### forceFailurePolicyIgnore

`values-kyverno.yaml` で `features.forceFailurePolicyIgnore.enabled: true` を設定。
kyverno がダウンしても webhook の `failurePolicy=Ignore` により他の Pod 操作がブロックされない。

### nodeAffinity (master ノード回避)

全 kyverno コンポーネント（admission/background/cleanup/reports controller）に
`node-role.kubernetes.io/control-plane: DoesNotExist` の nodeAffinity を設定。
master ノード (6GB RAM) の API サーバー遅延によるリース更新失敗を防止。

---

## トラブルシューティング

### cleanup Jobs / policyReportsCleanup のイメージについて

Kyverno の cleanup jobs と post-upgrade hook (`kyverno-clean-reports`) は `/bin/bash` を使うスクリプトを実行する。
また、Kyverno の securityContext で `runAsNonRoot: true` が強制されている。

| イメージ | 問題点 |
|---------|--------|
| `bitnami/kubectl` (Docker Hub) | Docker Hub から直接 pull 不可 (レート制限・認証問題) |
| `registry.k8s.io/kubectl` | root で実行されるため `runAsNonRoot=true` に非対応 |
| `cgr.dev/chainguard/kubectl` | 非 root だが `/bin/bash` がなく Helm chart のスクリプトが実行不可 |

**解決策:** Harbor の Docker Hub プロキシキャッシュを経由して `bitnami/kubectl` を取得する。

Harbor に Docker Hub プロキシを設定済み (Harbor UI → Registries → `docker-hub`、Projects → `dockerhub-proxy`)。
`values-kyverno.yaml` で全 cleanup jobs のイメージを `harbor.homelab.local/dockerhub-proxy/bitnami/kubectl:1.31` に設定している。
タグを `latest` ではなく固定バージョンにすることで、`imagePullPolicy` が `IfNotPresent` になり
Harbor 障害時もキャッシュ済みイメージで動作する。

### ArgoCD Sync Failed — CRD annotations サイズ超過

Kyverno CRD は ~560KB で Kubernetes の annotations サイズ上限 (262144 bytes) を超えるため、
ArgoCD の ServerSideApply が失敗する。

**解決策:**
1. `values-kyverno.yaml` で `crds.install: false` を設定 (Helm による CRD 管理を無効化)
2. 全 13 個の Kyverno CRD に `argocd.argoproj.io/sync-options=Prune=false` アノテーションを付与 (ArgoCD による削除を防止)

---

## アンインストール

```bash
kubectl delete -f policies/
helm uninstall kyverno -n kyverno
kubectl delete namespace kyverno
```
