# Trivy Operator

コンテナイメージ・設定・RBAC の継続的脆弱性スキャン。スキャン結果を k8s CRD として保存し Grafana で可視化する。

## 構成

| 項目 | 値 |
|------|-----|
| Helm chart | aquasecurity/trivy-operator 0.24.1 |
| Namespace | trivy-system |
| ArgoCD Sync Wave | 5 |
| スキャン間隔 | 24h |
| 並列スキャン数 | 3 |

## ファイル構成

```
k8s/trivy-operator/
├── values.yaml      # Helm values
├── README.md        # 本ファイル
└── GUIDE.md         # 概念説明・CRD一覧

k8s/argocd/apps/
└── trivy-operator.yaml   # ArgoCD Application
```

## セットアップ

### ArgoCD への登録

```bash
# Raspberry Pi 上で実行
kubectl apply -f k8s/argocd/apps/trivy-operator.yaml
```

## スキャン結果の確認

```bash
# 脆弱性レポート
kubectl get vulnerabilityreport -A

# 設定監査レポート
kubectl get configauditreport -A

# HIGH/CRITICAL のみ抽出
kubectl get vulnerabilityreport -A -o json | \
  jq '.items[] | select(.report.summary.criticalCount > 0 or .report.summary.highCount > 0) | .metadata.name'
```

## Grafana ダッシュボード

Grafana にダッシュボード ID `17813` をインポートするとスキャン結果を可視化できる。

## 詳細

CRD 種別・Harbor との統合・Kyverno との連携は [GUIDE.md](./GUIDE.md) を参照。
