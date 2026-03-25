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

## アンインストール

```bash
kubectl delete -f policies/
helm uninstall kyverno -n kyverno
kubectl delete namespace kyverno
```
