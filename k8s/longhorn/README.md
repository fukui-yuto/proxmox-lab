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
| レプリカ数 | 1 (ラボ向け) |
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
| `longhorn` | 1レプリカ・ReclaimPolicy: Retain | ✓ |
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

## 既存 PVC の移行手順 (実施済み: 2026-04-11)

local-path から Longhorn への全 PVC 移行を完了。以下に実施した手順を記録する。

### 前提: multipathd の干渉を防ぐ

Longhorn は iSCSI (IET VIRTUAL-DISK) を使ってボリュームをアタッチする。
multipathd がこれらを掴んでしまうと `mount failed: exit status 32` となり Pod がスタックする。

**k3s-master での対処 (`/etc/multipath.conf`):**

```
defaults {
    user_friendly_names yes
}

blacklist {
    device {
        vendor "IET"
        product "VIRTUAL-DISK"
    }
}
```

適用コマンド:
```bash
sudo multipath -f <mpathX>     # 掴んでいるデバイスをリリース
sudo multipathd reconfigure    # 設定再読み込み
```

> **注意**: 他のノードでも同様の問題が発生する可能性がある。新規ノード追加時は `/etc/multipath.conf` に同様のブラックリストを追加すること。

### 移行手順 (StatefulSet の場合)

StatefulSet の PVC は volumeClaimTemplates で自動作成されるため、古い PVC を削除してから再作成する。

**ただし PVC 削除は詰まりやすい** — `kubectl delete pvc` が Terminating のままハングする場合がある。
代わりに **PGDATA サブディレクトリ** の活用 (PostgreSQL) など、データ損失なしに移行できる方法を優先すること。

#### PostgreSQL (keycloak-postgresql) の移行例

Longhorn ボリュームルートに `lost+found` が存在するため、initdb がエラーになる問題への対処:

```yaml
# keycloak.yaml の PostgreSQL コンテナに PGDATA env var を追加
env:
  - name: PGDATA
    value: /var/lib/postgresql/data/pgdata  # サブディレクトリを使用
```

これにより PVC 削除なしで initdb エラーを回避できる。

#### Harbor Database の権限修正

Harbor の postgres コンテナが `/var/lib/postgresql/data/pgdata` のパーミッション不正で起動しない場合:

```yaml
# 一時 Job でパーミッション修正
apiVersion: batch/v1
kind: Job
metadata:
  name: fix-harbor-db-permissions
  namespace: harbor
spec:
  template:
    spec:
      restartPolicy: Never
      nodeSelector:
        kubernetes.io/hostname: k3s-master  # PVC がアタッチされているノードに固定
      containers:
        - name: fix-perms
          image: postgres:16-alpine
          command: ["sh", "-c", "chmod -R 700 /data/pgdata && ls -la /data/pgdata/"]
          volumeMounts:
            - name: db-data
              mountPath: /data
          securityContext:
            runAsUser: 0
      volumes:
        - name: db-data
          persistentVolumeClaim:
            claimName: database-data-harbor-database-0
```

### デフォルト StorageClass の変更

k3s は起動時に `local-path` をデフォルト StorageClass に設定するため、Longhorn 導入後は手動で変更が必要:

```bash
kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
```

> **注意**: k3s 再起動のたびにリセットされる可能性がある。恒久的に無効化するには k3s のインストール時に `--disable=local-storage` オプションを追加する (`terraform/main.tf` の remote-exec で管理)。

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

### ボリュームが Faulted (レプリカ failedAt) になる

ノード再起動や Longhorn manager のクラッシュ後、レプリカが `failedAt` 付きで停止しボリュームが faulted になることがある。

**復旧手順:**
```bash
# 1. failed レプリカを特定
kubectl get replicas.longhorn.io -n longhorn-system -o json | \
  jq '.items[] | select(.spec.failedAt != "" and .spec.failedAt != null) | .metadata.name'

# 2. failedAt をクリアして回復させる
kubectl patch replicas.longhorn.io <replica-name> -n longhorn-system \
  --type merge -p '{"spec":{"failedAt":""}}'
```

### ボリュームが Degraded になる

レプリカ数が 2 以上の場合、ノードが不足していると発生する。レプリカ数 1 であれば通常は発生しない。
```bash
# Longhorn ノードの状態確認
kubectl get nodes.longhorn.io -n longhorn-system
```

### ボリュームが Faulted (TooManySnapshots) になる

スナップショット数が上限 (`snapshotMaxCount`) を超えるとボリュームが faulted になり、I/O エラーでアプリがクラッシュする。

**原因:** DNS 障害や CNI 再起動で Longhorn manager 間通信が途絶した際、スナップショットの自動パージが動作せず蓄積する。

**復旧手順:**
```bash
# 1. faulted ボリュームの確認
kubectl get volumes.longhorn.io -n longhorn-system -o json | \
  jq '.items[] | select(.status.robustness == "faulted") | {name: .metadata.name, state: .status.state}'

# 2. faulted ボリュームを使用する Pod を停止 (ボリュームを detach させる)
# 対象 StatefulSet/Deployment を replicas=0 にする

# 3. instance-manager Pod を全削除 (ネットワーク不整合の解消)
kubectl delete pods -n longhorn-system -l longhorn.io/component=instance-manager

# 4. スタックした VolumeAttachment を削除
kubectl get volumeattachments -o json | \
  jq '.items[] | select(.status.attached == false) | .metadata.name' | \
  xargs -I {} kubectl delete volumeattachment {}

# 5. ボリュームが detached → attached (healthy) に遷移するのを確認
kubectl get volumes.longhorn.io -n longhorn-system -w

# 6. 停止した Pod を復元 (replicas を元に戻す / ArgoCD が自動復元)
```

**予防策:** `values-longhorn.yaml` で `snapshotMaxCount: 100` (デフォルト 250 → 100 に削減) と自動クリーンアップを有効化済み。

### Cilium 再起動後に Longhorn が不安定になる

Cilium DaemonSet のローリングリスタート後、既存の Longhorn instance-manager Pod のネットワークが壊れ、ボリュームの attach/detach がスタックする。

**対処:** Cilium 再起動完了後に instance-manager を全削除する:
```bash
kubectl delete pods -n longhorn-system -l longhorn.io/component=instance-manager
```
