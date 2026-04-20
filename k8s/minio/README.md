# MinIO

S3 互換オブジェクトストレージ。Velero のバックアップ先として使用。

## デプロイ

ArgoCD の App of Apps (root app) が自動で管理する。手動操作は不要。

```
Helm chart : minio/minio 5.2.0
Namespace  : minio
Wave       : 3 (vault と同タイミング)
```

## アクセス情報

| 項目 | 値 |
|------|-----|
| コンソール URL | http://minio.homelab.local |
| API エンドポイント | http://minio-api.homelab.local |
| Root 認証 | `admin` / `Minio12345` |
| OIDC 認証 | **Login with SSO** → Keycloak (`admin` / `Keycloak12345`) |

> OIDC ユーザーには `consoleAdmin` ポリシーが自動付与される (Keycloak hardcoded claim)。

Windows hosts ファイルへの追記:
```powershell
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.25  minio.homelab.local"
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.25  minio-api.homelab.local"
```

## 事前作成バケット

| バケット名 | 用途 |
|-----------|------|
| `velero-backups` | Velero バックアップ保存先 |

## バケットの追加

`values-minio.yaml` の `buckets` に追記して git push する。ArgoCD が自動で適用する。

```yaml
buckets:
  - name: velero-backups
    policy: none
    purge: false
  - name: new-bucket      # 追加
    policy: none
    purge: false
```

## トラブルシューティング

### bitnami/minio イメージが pull できない

bitnami は古いイメージタグを Docker Hub から定期削除する。公式チャート (`charts.min.io`) を使うこと。
本リポジトリでは公式チャートを使用済み。

### ArgoCD で Deployment の spec.selector immutable エラー

チャートを bitnami → 公式に切り替えた際に発生する。
古い Deployment を削除すれば解消する：

```bash
# k3s-master にて
kubectl delete deployment minio -n minio
```

ArgoCD が自動で再作成する。
