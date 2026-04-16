# Velero ガイド

## Velero とは

Kubernetes クラスターのバックアップ・リストア・マイグレーションツール。
以下の2種類のバックアップに対応する:

| 種別 | 対象 | 仕組み |
|------|------|--------|
| リソースバックアップ | Deployment, ConfigMap, Secret 等の k8s オブジェクト | etcd から取得 → S3 に保存 |
| ボリュームバックアップ | PVC のデータ | File System Backup (FSB) で Pod 内からコピー |

## homelab での構成

```
┌─────────────────────────────────────────────┐
│  Kubernetes クラスター                       │
│                                             │
│  ┌─────────┐  バックアップ  ┌──────────┐    │
│  │ velero  │ ──────────► │  MinIO   │    │
│  │  Pod    │              │ (S3互換) │    │
│  └─────────┘              └──────────┘    │
│       ↑                        ↑           │
│  Schedule CRD              Longhorn PVC    │
│  (毎日 02:00 JST)                          │
└─────────────────────────────────────────────┘
```

## バックアップの仕組み

### リソースバックアップ

1. Velero が Kubernetes API から全リソースの YAML を取得
2. gzip 圧縮して MinIO の `velero-backups/` に保存
3. バックアップのメタデータを `BackupStorageLocation` に登録

### ボリュームバックアップ (FSB)

`defaultVolumesToFsBackup: true` が設定されているため、PVC も自動でバックアップされる。

1. Velero が各 Pod にサイドカーとして `node-agent` を配置 (DaemonSet)
2. `node-agent` が Pod のファイルシステムを直接読み取りバックアップ
3. MinIO に保存

> Longhorn のスナップショットを使う方式 (CSI スナップショット) より互換性が高い。

## リストアの仕組み

```
バックアップ (MinIO)
    │
    ↓  velero restore create
k8s リソースの再作成 → PVC 作成 → データ復元
```

namespace ごと、または特定リソースのみリストア可能:

```bash
# namespace 単位でリストア
velero restore create --from-backup daily-backup --include-namespaces monitoring

# 特定リソースのみ
velero restore create --from-backup daily-backup \
  --include-resources deployments,services
```

## ArgoCD との共存

Velero でリストアしたリソースは ArgoCD の管理外になる場合がある。
リストア後は ArgoCD の sync を実行して状態を同期する:

```
argocd app sync <app-name>
```

## CRD 管理方針 (ArgoCD 管理下)

通常の Helm インストールでは `upgradeCRDs: true` (デフォルト) で
PreSync フックが bitnami/kubectl イメージで CRD をインストールする。

ArgoCD 管理下では ArgoCD 自身が `ServerSideApply` で CRD を管理するため
`upgradeCRDs: false` にする。これにより:

- 不要な init container が起動しない
- 壊れたイメージタグによる起動失敗を回避
- CRD の管理が ArgoCD に一元化される
