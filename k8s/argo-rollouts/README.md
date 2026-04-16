# Argo Rollouts

プログレッシブデリバリー (カナリア / Blue-Green デプロイ) コントローラー。

## 構成

| 項目 | 値 |
|------|-----|
| Helm chart | argoproj/argo-rollouts 2.38.0 |
| Namespace | argo-rollouts |
| ArgoCD Sync Wave | 4 |
| Dashboard | http://argo-rollouts.homelab.local |

## ファイル構成

```
k8s/argo-rollouts/
├── values.yaml          # Helm values
├── README.md            # 本ファイル
└── GUIDE.md             # 概念説明・使い方

k8s/argocd/apps/
└── argo-rollouts.yaml   # ArgoCD Application
```

## セットアップ

### hosts ファイルへの追記

```powershell
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.24  argo-rollouts.homelab.local"
```

### ArgoCD への登録

```bash
# Raspberry Pi 上で実行
kubectl apply -f k8s/argocd/apps/argo-rollouts.yaml
```

## 操作

### kubectl プラグインのインストール (Raspberry Pi)

```bash
curl -LO https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64
chmod +x kubectl-argo-rollouts-linux-amd64
sudo mv kubectl-argo-rollouts-linux-amd64 /usr/local/bin/kubectl-argo-rollouts
```

### Rollout の確認

```bash
kubectl argo rollouts list rollouts -A
kubectl argo rollouts get rollout <name> -n <namespace> --watch
```

### 手動昇格 (カナリア一時停止中)

```bash
kubectl argo rollouts promote <name> -n <namespace>
```

### ロールバック

```bash
kubectl argo rollouts undo <name> -n <namespace>
```

## 詳細

概念・デプロイ戦略・Analysis の詳細は [GUIDE.md](./GUIDE.md) を参照。
