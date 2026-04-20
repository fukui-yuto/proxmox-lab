# Longhorn 詳細ガイド — 分散ブロックストレージ

## このツールが解決する問題

Kubernetes の Pod は「使い捨て」。Pod が再起動・移動するとローカルディスクのデータは消える。
データベースやファイル保存が必要なアプリには「永続ボリューム (PV)」が必要だが、
素の k8s にはノードをまたいだストレージ機能がない。

| 問題 | 内容 |
|------|------|
| データ消失 | Pod 再起動でローカルデータが消える |
| ノード障害 | 特定ノードのディスクが壊れると復旧不可 |
| スケジューリング | データが特定ノードにしかないと Pod が移動できない |
| 管理の煩雑さ | NFS を手動で建てるのは運用負荷が高い |

Longhorn は各ノードのローカルディスクを束ねて「分散ブロックストレージ」を提供し、
Pod がどのノードに移動してもデータにアクセスできるようにする。

---

## 分散ブロックストレージとは

```
従来 (hostPath):
  Pod → 特定ノードのディスク (Pod が別ノードに移動するとデータ見えない)

Longhorn:
  Pod → Longhorn Volume → [レプリカ1: node01] [レプリカ2: node02] [レプリカ3: node03]
                           ↑ どこからでもアクセス可能。1台壊れても他にコピーがある
```

各ボリュームはブロックデバイス (仮想ディスク) として Pod にマウントされる。
ファイルシステムレベルではなくブロックレベルでレプリケーションするため、
どんなファイルシステム (ext4, xfs) でも使える。

---

## Longhorn のアーキテクチャ

```
┌─────────────────────────────────────────────────────────┐
│  Kubernetes クラスター                                    │
│                                                         │
│  ┌────────────────┐   ┌────────────────┐               │
│  │ Longhorn       │   │ Longhorn UI    │               │
│  │ Manager        │   │ (Web ダッシュ)   │               │
│  │ (DaemonSet)    │   └────────────────┘               │
│  │ 全ノードで稼働   │                                     │
│  └───────┬────────┘                                     │
│          │ 管理                                         │
│  ┌───────┴─────────────────────────────────────────┐    │
│  │  Engine (各ボリュームにつき1つ)                      │    │
│  │  ├─ Replica (node01: /var/lib/longhorn/...)     │    │
│  │  ├─ Replica (node02: /var/lib/longhorn/...)     │    │
│  │  └─ Replica (node03: /var/lib/longhorn/...)     │    │
│  └─────────────────────────────────────────────────┘    │
│                                                         │
│  ┌─────────────────┐                                    │
│  │ CSI Driver      │ ← Kubernetes の PVC と Longhorn を繋ぐ │
│  └─────────────────┘                                    │
└─────────────────────────────────────────────────────────┘
```

| コンポーネント | 役割 |
|--------------|------|
| **Longhorn Manager** | 全ノードで動く DaemonSet。ボリュームの作成・スナップショット・レプリカ管理 |
| **Longhorn Engine** | 各ボリュームの I/O を処理するプロセス。レプリカへの読み書きを制御 |
| **Replica** | ボリュームのデータ実体。各ノードのディスク上のファイル |
| **CSI Driver** | Kubernetes の PersistentVolumeClaim (PVC) を Longhorn ボリュームに接続 |
| **Longhorn UI** | Web ダッシュボードでボリュームの状態をGUIで確認 |

---

## Kubernetes のストレージの仕組み (PV / PVC / StorageClass)

```
アプリ開発者:                    インフラ管理者:
  PVC (ほしいサイズ・種類を宣言)     StorageClass (どう作るかの設定)
       ↓                              ↓
  「10GB のディスクください」      「Longhorn でレプリカ1で作る」
       ↓                              ↓
       └──────── Kubernetes ──────────┘
                      ↓
                PV が自動作成される (Dynamic Provisioning)
                      ↓
                Pod にマウントされる
```

| 概念 | 一言 | 例え |
|------|------|------|
| **PersistentVolume (PV)** | 実際のディスク | USB メモリの実体 |
| **PersistentVolumeClaim (PVC)** | 「このサイズのディスクが欲しい」という要求 | 「USB メモリ貸して」という申請書 |
| **StorageClass** | ディスクの作り方のテンプレート | 「USB は Longhorn ブランドで」 |

---

## ファイル構成と各ファイルの解説

### `namespace.yaml` — Namespace の作成

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: longhorn-system
```

Longhorn 専用の「部屋」を作る。全 Longhorn リソースはこの namespace に入る。

---

### `iscsi-installer.yaml` — iSCSI の前提パッケージを自動インストール

Longhorn はブロックデバイスを Pod に接続するために **iSCSI** プロトコルを使う。
各ノードに `open-iscsi` パッケージが必要だが、手動で全ノードに入れるのは面倒。
この DaemonSet が **全ノードに自動で iSCSI をインストール**する。

```yaml
apiVersion: apps/v1
kind: DaemonSet              # ← 全ノードに1つずつ Pod を配置するリソース
metadata:
  name: longhorn-iscsi-installation
  namespace: longhorn-system
spec:
  selector:
    matchLabels:
      app: longhorn-iscsi-installation
  template:
    spec:
      hostNetwork: true      # ← ノードのネットワークを直接使う
      hostPID: true          # ← ノードのプロセス空間にアクセス
      initContainers:        # ← メインコンテナより先に実行される「準備コンテナ」
        - name: install-iscsi
          image: harbor.homelab.local/proxy/library/ubuntu:22.04
          command:
            - nsenter                    # ← ノードの名前空間に入るコマンド
            - --mount=/proc/1/ns/mnt     # ← ノードのファイルシステムを見る
            - --
            - bash
            - -c
            - |
              # open-iscsi が未インストールならインストール
              if ! dpkg -l open-iscsi &>/dev/null; then
                apt-get update -qq
                apt-get install -y open-iscsi
              fi
              # iscsid サービスを有効化・起動
              systemctl enable iscsid || true
              systemctl start iscsid || true
          securityContext:
            privileged: true   # ← ノードのカーネル操作に必要な特権
      containers:
        - name: pause
          image: harbor.homelab.local/proxy/library/busybox:1.36
          command: ["sh", "-c", "sleep infinity"]  # ← 何もせず待機 (DaemonSet を維持するため)
          resources:
            requests:
              cpu: 1m
              memory: 4Mi
      tolerations:
        - operator: Exists   # ← どんな taint のノードでも配置 (master含む)
```

**ポイント:**
- `DaemonSet` = 全ノードに1つずつ自動配置されるリソース
- `initContainers` = メインコンテナが起動する前に1回だけ実行される
- `nsenter` = コンテナの中からノードの OS を直接操作する Linux コマンド
- `privileged: true` = ノードのカーネルに直接アクセスする権限
- `tolerations: Exists` = master ノード (NoSchedule taint あり) にも配置する

---

### `values-longhorn.yaml` — Longhorn Helm values

#### defaultSettings セクション — Longhorn の動作設定

```yaml
defaultSettings:
  # レプリカ数: 1
  # 本番なら 2-3 にするが、ラボはディスク容量が少ないので 1
  # 2 にすると「スケジュール済み容量 > 最大容量」になり全ボリュームが障害になる
  defaultReplicaCount: 1

  # データの保存先パス
  defaultDataPath: /var/lib/longhorn

  # ディスクの空き容量が 25% 以下になったら新規ボリュームを割り当てない
  storageMinimalAvailablePercentage: 25

  # ディスク容量の何%までボリュームを割り当てられるか (200% = 2倍まで)
  # 高すぎると容量不足で障害の連鎖が起きる
  storageOverProvisioningPercentage: 200

  # レプリカが偏ったら自動で再配置
  replicaAutoBalance: best-effort

  # ノードがダウンしたときの Pod の扱い
  # "delete-both-..." = StatefulSet/Deployment の Pod を強制削除して別ノードで再起動
  # デフォルトだと Pod が Terminating のまま残り続ける
  nodeDownPodDeletionPolicy: delete-both-statefulset-and-deployment-pod

  # ボリュームが予期せず detach されたら Pod を自動削除 (自動復旧)
  autoDeletePodWhenVolumeDetachedUnexpectedly: true

  # スナップショットが溜まりすぎるとボリューム障害になるため自動削除
  autoCleanupSystemGeneratedSnapshot: true
  autoCleanupRecurringJobBackupSnapshot: true
  snapshotMaxCount: 100
```

#### persistence セクション — StorageClass の設定

```yaml
persistence:
  defaultClass: true           # Longhorn をデフォルト StorageClass にする
  defaultClassReplicaCount: 1  # PVC 作成時のデフォルトレプリカ数
  defaultFsType: ext4          # ファイルシステムの種類
  reclaimPolicy: Retain        # PVC 削除してもデータは残す (安全側)
```

`reclaimPolicy` の違い:
- `Delete`: PVC を消すとデータも消える（開発環境向け）
- `Retain`: PVC を消してもデータは残る（本番向け・誤削除防止）

#### ingress セクション — Web UI へのアクセス

```yaml
ingress:
  enabled: true
  ingressClassName: traefik
  host: longhorn.homelab.local   # ブラウザでアクセスする URL
  tls: false
```

#### リソース制限

```yaml
longhornManager:    # 全ノードで動く管理デーモン
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 300m
      memory: 256Mi

longhornUI:         # Web ダッシュボード
  replicas: 1
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
```

---

## データの流れ

```
1. アプリが PVC を要求
   kind: PersistentVolumeClaim
   spec:
     storageClassName: longhorn
     resources:
       requests:
         storage: 10Gi

2. Longhorn CSI Driver が PV を動的に作成
   → Engine プロセス起動
   → Replica をノードのディスクに作成

3. Pod にブロックデバイスとしてマウント
   Pod 内: /data/ ← ここに書き込むとレプリカに保存される

4. Pod が別ノードに移動しても
   → Engine が新しいノードで起動
   → 既存の Replica に接続
   → データはそのまま利用可能
```

---

## よく見るトラブルと対処

| 症状 | 原因 | 対処 |
|------|------|------|
| Volume が `Faulted` | レプリカ全滅 or スナップショット上限超過 | `snapshotMaxCount` 確認、レプリカ再構築 |
| PVC が `Pending` のまま | ストレージ容量不足 | `storageOverProvisioningPercentage` や実容量を確認 |
| Pod が `ContainerCreating` で停止 | iSCSI が起動していない | `iscsi-installer` DaemonSet の状態確認 |
| ノード障害後に Pod が動かない | `nodeDownPodDeletionPolicy` が `do-nothing` | 上記設定で自動復旧を有効化 |

---

## Longhorn と他のストレージの比較

| 項目 | Longhorn | NFS | hostPath |
|------|----------|-----|----------|
| レプリケーション | あり (自動) | なし (単一障害点) | なし |
| Pod の移動 | 自由 | 自由 | 不可 (ノード固定) |
| スナップショット | あり | なし | なし |
| 管理の手軽さ | Helm で一発 | NFS サーバー構築必要 | 設定不要だが運用困難 |
| 性能 | ネットワーク越し | ネットワーク越し | ローカルディスク直接 |
