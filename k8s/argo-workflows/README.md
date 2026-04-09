# Argo Workflows

k3s クラスター上に Argo Workflows をデプロイする。
AIOps の自動修復 Runbook (OOMKilled / CrashLoopBackOff) を Workflow として実行するために使用する。

## 構成

- **chart**: `argo-workflows` v0.45.7 (https://argoproj.github.io/argo-helm)
- **namespace**: `argo`
- **ArgoCD app**: `argo-workflows`
- **Sync Wave**: 3 (monitoring と同タイミング)
- **Sync 方式**: 手動 (オンデマンド)

---

## デプロイ手順

ArgoCD UI または kubectl で手動 Sync する。

```bash
# ArgoCD Application を適用
kubectl apply -f k8s/argocd/apps/argo-workflows.yaml

# Pod が Ready になるまで待機
kubectl get pods -n argo -w
```

---

## アクセス

### Windows hosts ファイルへの追記

```powershell
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.24  argo-workflows.homelab.local"
```

### URL

| URL | 説明 |
|-----|------|
| http://argo-workflows.homelab.local | Argo Workflows UI (認証不要) |

> `--auth-mode=server` でログイン不要に設定している (homelab 用)。

---

## 自動修復での使用方法

aiops の auto-remediation コンポーネントが WorkflowTemplate を `aiops` namespace に作成する。
Argo Events の Sensor がアラートを受信すると、以下の WorkflowTemplate が起動される。

| WorkflowTemplate | トリガー | アクション |
|---|---|---|
| `remediate-oomkilled` | Pod OOMKilled | Deployment のメモリリミットを 1.5 倍に自動増加 |
| `remediate-crashloop` | Pod CrashLoopBackOff (2分継続) | ログ収集 + エラーパターン分析 → Grafana アノテーション記録 |

```bash
# WorkflowTemplate の確認
kubectl get workflowtemplate -n aiops

# Workflow 実行履歴の確認
kubectl get workflows -n aiops

# 手動でテスト Workflow を起動する場合
kubectl create -n aiops -f - << 'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: test-oomkilled-
spec:
  workflowTemplateRef:
    name: remediate-oomkilled
  arguments:
    parameters:
      - name: namespace
        value: "default"
      - name: pod
        value: "test-pod"
      - name: container
        value: "test-container"
EOF
```

---

## 動作確認

```bash
# Pod 状態確認
kubectl get pods -n argo

# 期待する出力
NAME                                  READY   STATUS    RESTARTS
argo-workflows-server-xxxxx           1/1     Running   0
argo-workflows-workflow-controller-xx 1/1     Running   0

# Argo Workflows UI をブラウザで確認
# → http://argo-workflows.homelab.local
```

---

## アンインストール

```bash
kubectl delete application argo-workflows -n argocd
kubectl delete namespace argo
```
