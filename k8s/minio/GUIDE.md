# MinIO ガイド

## MinIO とは

MinIO は S3 互換の高性能オブジェクトストレージ。AWS S3 と同じ API を提供するため、
S3 対応ツール (Velero, Grafana Loki, MLflow など) をそのまま利用できる。

## homelab での役割

```
┌─────────────┐   バックアップ   ┌─────────────────────┐
│   Velero    │ ────────────► │  MinIO              │
│ (k8s DR)    │               │  velero-backups/    │
└─────────────┘               └─────────────────────┘
                                    ↑ Longhorn PVC (20Gi)
```

## アーキテクチャ

| コンポーネント | 役割 |
|--------------|------|
| MinIO Server | オブジェクトストレージ本体 (API: 9000番ポート) |
| MinIO Console | Web UI (9001番ポート) |
| PVC (Longhorn) | データ永続化 (20Gi) |

## S3 互換 API

MinIO は AWS S3 と同じエンドポイント仕様を持つ:

```
エンドポイント: http://minio.minio.svc.cluster.local:9000
バケット操作  : s3://bucket-name/path/to/object
```

クラスター内からアクセスする場合は `minio.minio.svc.cluster.local:9000` を S3 URL として指定する。

## Velero との連携

Velero は MinIO を AWS S3 として認識する。接続設定:

```yaml
configuration:
  backupStorageLocation:
    provider: aws
    bucket: velero-backups
    config:
      region: minio          # MinIO では任意の文字列でよい
      s3ForcePathStyle: true # パス形式 (MinIO に必要)
      s3Url: http://minio.minio.svc.cluster.local:9000
```

## ストレージ拡張

`values-minio.yaml` の `persistence.size` を変更して git push するだけ。
Longhorn が動的に PVC を再作成する。

> ⚠️ サイズの縮小はできない。拡大のみ可能。
