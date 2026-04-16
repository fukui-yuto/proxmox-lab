# Backstage

開発者ポータル / サービスカタログ。全 k8s サービスのドキュメント・状態・依存関係にワンストップでアクセスできる。

## 構成

| 項目 | 値 |
|------|-----|
| Helm chart | backstage/backstage 1.9.6 |
| Namespace | backstage |
| ArgoCD Sync Wave | 16 |
| URL | http://backstage.homelab.local |
| DB | PostgreSQL (Longhorn 5Gi) |

## ファイル構成

```
k8s/backstage/
├── values.yaml      # Helm values
├── README.md        # 本ファイル
└── GUIDE.md         # 概念説明・カタログ登録・プラグイン

k8s/argocd/apps/
└── backstage.yaml   # ArgoCD Application
```

## セットアップ

### hosts ファイルへの追記

```powershell
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.24  backstage.homelab.local"
```

### ArgoCD への登録

```bash
# Raspberry Pi 上で実行
kubectl apply -f k8s/argocd/apps/backstage.yaml
```

### Kubernetes ServiceAccount Token の作成

Backstage が k8s クラスターにアクセスするための ServiceAccount を作成する:

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: backstage
  namespace: backstage
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: backstage-cluster-reader
subjects:
  - kind: ServiceAccount
    name: backstage
    namespace: backstage
roleRef:
  kind: ClusterRole
  name: view
  apiGroup: rbac.authorization.k8s.io
EOF

# Token を取得して values.yaml の K8S_SERVICE_ACCOUNT_TOKEN に設定
kubectl create token backstage -n backstage --duration=8760h
```

## カタログへのサービス登録

各サービスのリポジトリに `catalog-info.yaml` を追加して `values.yaml` の `catalog.locations` に URL を追記する。

詳細は [GUIDE.md](./GUIDE.md) を参照。
