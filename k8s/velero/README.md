# Velero

k8s リソースと PVC の定期バックアップ・DR ツール。MinIO を S3 バックエンドとして使用。

## デプロイ

ArgoCD の App of Apps が自動で管理する。

```
Helm chart  : vmware-tanzu/velero 7.1.4
Namespace   : velero
Wave        : 4 (minio の後)
バックエンド : MinIO (minio namespace)
```

> **重要**: Velero Helm チャートはデフォルトで `upgradeCRDs: true` だが、
> ArgoCD 管理下では `upgradeCRDs: false` + `ServerSideApply=true` を使う。
> `upgradeCRDs: true` は `bitnami/kubectl` イメージを使う init container を起動するが、
> このイメージのタグが存在しない場合がある (例: `bitnami/kubectl:1.34`)。

## バックアップスケジュール

| スケジュール名 | 時刻 | 保持期間 | 対象 |
|--------------|------|---------|------|
| `velero-daily-backup` | 毎日 02:00 JST (17:00 UTC) | 7日間 | 全 namespace (kube-system 等除く) |

## バックアップの確認

```bash
# バックアップ一覧
kubectl get backup -n velero

# バックアップ詳細
kubectl describe backup <backup-name> -n velero

# スケジュール確認
kubectl get schedule -n velero
```

## 手動バックアップ

```bash
kubectl create -n velero -f - <<EOF
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: manual-backup-$(date +%Y%m%d)
spec:
  includedNamespaces:
    - "*"
  storageLocation: default
  ttl: 720h
EOF
```

## リストア手順

```bash
# バックアップ一覧から選択
kubectl get backup -n velero

# リストア実行
velero restore create --from-backup <backup-name>

# リストア状態確認
kubectl get restore -n velero
```

## BackupStorageLocation の確認

```bash
kubectl get backupstoragelocation -n velero
# PHASE が "Available" であることを確認
```

## トラブルシューティング

### `bitnami/kubectl:1.34 not found` で init container が失敗する

`upgradeCRDs: false` になっているか確認する:

```bash
kubectl get deploy velero -n velero -o jsonpath='{.spec.template.spec.initContainers}'
```

init container が存在しない (空配列) なら正常。存在する場合は values を確認。

### velero-upgrade-crds Job が詰まっている

古い Helm リリースから残った Job がある場合:

```bash
# 強制削除 (--force で即座に削除)
kubectl delete job velero-upgrade-crds -n velero --grace-period=0 --force
```

> ⚠️ `kubectl delete` が応答しない場合は、Raspberry Pi 上でプロセスが残っている可能性がある。
> `ps aux | grep kubectl` で確認し、該当 PID を `kill` してから再実行する。

### BackupStorageLocation が Unavailable

MinIO が起動していない、または認証情報が間違っている。

```bash
# MinIO Pod の確認
kubectl get pods -n minio

# velero の認証 Secret 確認
kubectl get secret velero -n velero -o yaml
```

### CRD not found エラーで sync が失敗する

Velero CRD が未登録の場合。`upgradeCRDs: false` かつ `ServerSideApply=true` の場合、
ArgoCD が CRD を適用するが登録完了まで時間がかかる。

再 sync すれば解消する:
```
argocd app sync velero
```
