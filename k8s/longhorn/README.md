# Longhorn — 分散永続ストレージ

Kubernetes クラスター上のデータを複数ノードにレプリケートして保持する分散ブロックストレージ。
Pod が別ノードに再スケジュールされてもデータが失われない。

---

## 構成概要

| 項目 | 値 |
|------|----|
| Helm chart | longhorn/longhorn |
| バージョン | 1.6.2 |
| Namespace | longhorn-system |
| デフォルト StorageClass | `longhorn` |
| レプリカ数 | 2 |
| UI | http://longhorn.homelab.local |
| Sync Wave | 2 (kyverno-policies の次) |

---

## デプロイ手順

### 1. ArgoCD Application 登録

```bash
kubectl apply -f k8s/argocd/apps/longhorn.yaml
```

または `register-apps.sh` の Wave 2 で自動登録される。

### 2. 動作確認

```bash
# Longhorn Pod の起動確認
kubectl get pods -n longhorn-system

# StorageClass の確認 (longhorn が default になっていること)
kubectl get storageclass

# Longhorn UI
# http://longhorn.homelab.local
```

---

## StorageClass

| StorageClass | 説明 | デフォルト |
|--------------|------|----------|
| `longhorn` | 2レプリカ・ReclaimPolicy: Retain | ✓ |
| `local-path` | ノードローカル (k3s デフォルト) | — |

Longhorn 導入後は `local-path` に代わり `longhorn` がデフォルトになる。

---

## 対象アプリの PVC

以下のアプリが `storageClass: longhorn` を使用するよう設定済み:

| アプリ | PVC | サイズ |
|--------|-----|--------|
| Vault | dataStorage | 10Gi |
| Harbor | registry | 10Gi |
| Harbor | database | 5Gi |
| Harbor | jobservice | 5Gi |
| Harbor | redis | 5Gi |
| Harbor | trivy | 5Gi |
| Elasticsearch | data | 10Gi |
| Keycloak PostgreSQL | data | 5Gi |

合計: 約 55Gi

---

## 既存 PVC の移行手順

既に local-path で作成された PVC を Longhorn に移行する場合、データを再作成する必要がある。

> **注意**: 以下の手順を実行するとそのアプリのデータは失われる。
> 必要に応じて事前にバックアップを取ること。

### 例: Elasticsearch の PVC 移行

```bash
# 1. ArgoCD で elasticsearch を一時的に停止 (suspend)
kubectl scale statefulset elasticsearch-master -n logging --replicas=0

# 2. 古い PVC を削除
kubectl delete pvc elasticsearch-master-elasticsearch-master-0 -n logging

# 3. ArgoCD で再 Sync → 新しい Longhorn PVC が自動作成される
```

### 例: Harbor の PVC 移行

```bash
# 1. Harbor を停止
kubectl scale deployment harbor-core harbor-registry harbor-jobservice -n harbor --replicas=0

# 2. 古い PVC を削除
kubectl delete pvc -n harbor -l app=harbor

# 3. ArgoCD で再 Sync
```

---

## トラブルシューティング

### open-iscsi が未インストールのノードがある

Longhorn Manager ログで `iscsiadm: command not found` が出る場合、
`longhorn-iscsi-installation` DaemonSet が正常に完了していない。

```bash
# DaemonSet の状態確認
kubectl get daemonset longhorn-iscsi-installation -n longhorn-system
kubectl logs -n longhorn-system -l app=longhorn-iscsi-installation --previous
```

### ボリュームが Degraded になる

レプリカ数 2 の設定だが、ノードが 1 台しか使用可能でない場合に発生する。
```bash
# Longhorn ノードの状態確認
kubectl get nodes.longhorn.io -n longhorn-system
```
