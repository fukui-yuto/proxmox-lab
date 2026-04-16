# Crossplane

Kubernetes CRD でインフラを宣言的管理。Proxmox VM を `kubectl apply` で作成・管理できる Terraform の代替。

## 構成

| 項目 | 値 |
|------|-----|
| Helm chart | crossplane-stable/crossplane 1.17.1 |
| Namespace | crossplane-system |
| ArgoCD Sync Wave | 16 |

## ファイル構成

```
k8s/crossplane/
├── values.yaml      # Helm values
├── README.md        # 本ファイル
└── GUIDE.md         # 概念説明・Provider設定・Terraform移行戦略

k8s/argocd/apps/
└── crossplane.yaml  # ArgoCD Application
```

## セットアップ

### ArgoCD への登録

```bash
# Raspberry Pi 上で実行
kubectl apply -f k8s/argocd/apps/crossplane.yaml
```

### Proxmox Provider のインストール

Crossplane 本体デプロイ後に Provider をインストールする:

```bash
kubectl apply -f - <<EOF
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-proxmox
spec:
  package: xpkg.upbound.io/upbound/provider-proxmox:v0.1.0
EOF
kubectl wait provider/provider-proxmox --for=condition=Healthy --timeout=5m
```

### 接続情報の登録

```bash
kubectl create secret generic proxmox-credentials \
  -n crossplane-system \
  --from-literal=credentials='{"username":"terraform@pve","password":"<password>","endpoint":"https://192.168.210.11:8006"}'
```

## 確認

```bash
# Provider の状態
kubectl get providers

# Managed Resource の状態
kubectl get managed

# Composite Resource の状態
kubectl get composite
```

## Terraform との使い分け

| 状況 | 推奨 |
|------|------|
| 既存 Proxmox VM の管理 | Terraform (現状維持) |
| 新規 VM・k8s から管理したいリソース | Crossplane |
| CNI / Storage 等の k8s 基盤 | ArgoCD + Helm |

## 詳細

Provider 設定・VM の宣言的管理例・Terraform からの移行戦略は [GUIDE.md](./GUIDE.md) を参照。
