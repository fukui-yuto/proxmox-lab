# 災害復旧 (Disaster Recovery) ガイド

本ドキュメントは Proxmox ホームラボ (3ノード構成 + k3s クラスター) の災害復旧手順をまとめたものである。

---

## 1. DR 方針

### RPO / RTO 目標

| 指標 | 目標 | 備考 |
|------|------|------|
| RPO (目標復旧時点) | 1時間以内 | Proxmox Replication が15分間隔のため、最大15分のデータロスを想定 |
| RTO (目標復旧時間) | 単一障害: 30分以内 / 全損: 4時間以内 | ホームラボのため厳密な SLA はないが、復旧手順の整備により短縮を目指す |

### バックアップの種類と対象

- **アプリケーションレベル**: Velero による k8s リソース + PVC のバックアップ
- **VM レベル**: Proxmox Backup Server による VM / LXC 全体のバックアップ
- **ストレージレベル**: Proxmox Replication による ZFS スナップショットのノード間複製
- **設定レベル**: Git リポジトリによる IaC 設定の管理

---

## 2. バックアップ構成

| ツール | 対象 | 保存先 | 頻度 |
|--------|------|--------|------|
| Velero | k8s リソース + PVC | MinIO (S3互換) | 定期スケジュール |
| Proxmox Backup Server | VM / LXC 全体 | PBS ストレージ | 毎日 |
| Proxmox Replication | ZFS スナップショット差分 | ノード間 (pve-node01 → pve-node02/03) | 15分ごと |
| Git (このリポジトリ) | IaC 設定ファイル (Terraform / Ansible / k8s マニフェスト) | GitHub | 変更時 |

### 各ツールの役割

- **Velero**: k8s 上のアプリケーションデータ (PersistentVolumeClaim) とリソース定義を MinIO にバックアップ。Longhorn 全損時の最終防衛線
- **Proxmox Backup Server**: VM ディスクイメージの増分バックアップ。VM が起動しない場合の復元に使用
- **Proxmox Replication**: pve-node01 の ZFS データセットを他ノードへ15分間隔で同期。ノード障害時の迅速な HA フェイルオーバーを支援
- **Git**: すべてのインフラ設定を GitHub に保存。クラスター全損時でも設定を完全に再現可能

---

## 3. 障害シナリオ別復旧手順

### シナリオ A: 単一ワーカー VM 障害

**影響範囲**: 該当ノード上の Pod が停止。他ワーカーに再スケジュールされる。

**自動回復**:
- Longhorn のレプリカが他ノードに存在するため、PVC データは自動的に利用可能
- k8s スケジューラが Pod を他の正常なワーカーに再配置

**手動復旧 (VM が起動しない場合)**:
1. Terraform で VM を再作成
   ```bash
   cd ~/proxmox-lab/terraform
   terraform plan   # 影響範囲を確認
   terraform apply  # VM 再作成
   ```
2. k3s への re-join は Terraform の `remote-exec` プロビジョナーで自動実行される
3. Longhorn がレプリカを新ノードに再構築するのを待つ

---

### シナリオ B: 単一 Proxmox ノード障害

#### pve-node01 障害

**影響**:
- k3s-master (VM 201) が停止 → kubectl 操作不能
- dns-ct (LXC 101) が停止 → DNS 解決不能
- Corosync: QDevice (Raspberry Pi) があればノード02/03 でクォーラム維持可能

**復旧手順**:
1. QDevice によりクォーラムが維持されていることを確認
2. HA 設定がある場合、VM は自動的に他ノードへフェイルオーバー
3. ノード修理後、Proxmox クラスターに再参加
4. Proxmox Replication で ZFS 同期を再開

#### pve-node02 障害

**影響**:
- k3s-worker03/04/05 (VM 204/205/206) が停止
- Pod は pve-node03 上のワーカー (06/07/08) に再スケジュール

**復旧**:
- ノード修理後にクラスター再参加。VM は自動起動する

#### pve-node03 障害

**影響**:
- k3s-worker06/07/08 (VM 207/208/209) が停止
- Pod は pve-node02 上のワーカー (03/04/05) に再スケジュール

**復旧**:
- ノード修理後にクラスター再参加。VM は自動起動する

---

### シナリオ C: k3s コントロールプレーン障害

**影響**:
- k3s-master (VM 201 / 192.168.210.21) が停止
- kubectl 操作不能、新規 Pod のスケジュール不可
- 既存の Pod は動作を継続する (kubelet は独立して動作)

**復旧手順**:

1. VM の再起動を試みる
   ```bash
   # Proxmox Web UI または CLI から
   qm start 201
   ```
2. VM が起動しない場合、PBS バックアップから復元
   ```bash
   qmrestore /var/lib/vz/dump/<backup-file> 201
   ```
3. 復元後、k3s サービスの起動を確認
   ```bash
   ssh root@192.168.210.21 systemctl status k3s
   ```
4. ワーカーノードが再接続されることを確認
   ```bash
   kubectl get nodes
   ```

---

### シナリオ D: Longhorn ストレージ全損

**影響**:
- PersistentVolume のデータが全て失われる
- StatefulSet のアプリ (Elasticsearch, Vault, Harbor 等) がデータロス

**復旧手順**:

1. Longhorn の状態を確認
   ```bash
   kubectl get volumes.longhorn.io -n longhorn-system
   ```
2. 全レプリカが失われている場合、Velero バックアップから復元
   ```bash
   # 利用可能なバックアップを確認
   velero backup get

   # 特定のバックアップから復元
   velero restore create --from-backup <backup-name>

   # namespace を指定して部分復元
   velero restore create --from-backup <backup-name> --include-namespaces <namespace>
   ```
3. 復元後、Pod とボリュームの状態を確認
   ```bash
   kubectl get pvc --all-namespaces
   kubectl get pods --all-namespaces | grep -v Running
   ```

---

### シナリオ E: 全クラスター再構築 (最悪ケース)

全ノードが使用不能になった場合の完全再構築手順。

**前提条件**:
- GitHub リポジトリ (proxmox-lab) にアクセス可能
- Raspberry Pi (管理端末) が稼働している
- MinIO バックアップデータが残っている (外部に退避済みの場合)

**復旧手順**:

1. **Proxmox インストール**
   - 各ノードに Proxmox VE を再インストール (PXE または USB)
   - クラスター構成を再作成 (`pvecm create` / `pvecm add`)

2. **ホスト OS 設定の復元**
   ```bash
   cd ~/proxmox-lab/ansible
   ansible-playbook -i inventory/hosts.yml playbooks/site.yml
   ```
   - NIC チューニング (`08-nic-tuning.yml`) が含まれることを確認

3. **VM 再作成**
   ```bash
   cd ~/proxmox-lab/terraform
   terraform init
   terraform apply
   ```
   - 全 VM / LXC が Terraform で再作成される
   - k3s クラスター構築は `remote-exec` で自動実行

4. **k3s クラスター構築の確認**
   ```bash
   kubectl get nodes
   kubectl get pods -n kube-system
   ```

5. **ArgoCD による全アプリ自動デプロイ**
   - ArgoCD がインストールされると GitHub リポジトリから全アプリを自動 Sync
   - Sync Wave に従い段階的に起動 (pve-node01 の NIC ハング防止)

6. **PVC データの復元**
   ```bash
   # Velero がデプロイされた後に実行
   velero restore create --from-backup <最新のバックアップ名>
   ```

7. **動作確認**
   - 全 Pod が Running であることを確認
   - 各サービスの Web UI にアクセスして正常性を確認
   - Longhorn ダッシュボードでボリュームの健全性を確認

---

## 4. 復旧コマンドリファレンス

### Velero

```bash
# バックアップ一覧の確認
velero backup get

# バックアップの詳細
velero backup describe <backup-name> --details

# 全リソースの復元
velero restore create --from-backup <backup-name>

# 特定 namespace のみ復元
velero restore create --from-backup <backup-name> --include-namespaces <namespace>

# 復元状態の確認
velero restore get
velero restore describe <restore-name>

# スケジュール確認
velero schedule get
```

### Proxmox

```bash
# VM バックアップから復元
qmrestore <backup-file> <vmid>

# LXC バックアップから復元
pct restore <ctid> <backup-file>

# レプリケーション状態の確認
pvesr status

# クラスターの状態確認
pvecm status

# クォーラム状態
pvecm expected 1  # 緊急時: 単一ノードでクォーラム強制 (注意して使用)
```

### Longhorn

```bash
# ボリューム状態の確認
kubectl get volumes.longhorn.io -n longhorn-system

# エンジンイメージの確認
kubectl get engineimages.longhorn.io -n longhorn-system

# instance-manager の再起動 (Cilium 再起動後に必要)
kubectl delete pods -n longhorn-system -l longhorn.io/component=instance-manager
```

### k3s

```bash
# k3s サービスの状態確認
systemctl status k3s

# k3s サービスの再起動
systemctl restart k3s

# k3s のアンインストール (再インストール時)
/usr/local/bin/k3s-uninstall.sh        # master
/usr/local/bin/k3s-agent-uninstall.sh   # worker
```

---

## 5. 定期確認事項

以下の項目を定期的に確認し、バックアップの健全性を維持する。

### 月次確認

- [ ] Velero バックアップの成功確認
  ```bash
  velero backup get
  ```
  - `Completed` 以外のステータスがないか確認
  - 最終バックアップが直近であることを確認

- [ ] PBS バックアップジョブの確認
  - Proxmox Web UI → Datacenter → Backup から最終実行日時を確認
  - 失敗ジョブがないか確認

- [ ] Longhorn レプリカの健全性
  ```bash
  kubectl get volumes.longhorn.io -n longhorn-system
  ```
  - 全ボリュームが `healthy` であることを確認
  - `degraded` のボリュームがあれば原因を調査

### 四半期確認

- [ ] GitHub リポジトリとラボの設定の乖離がないか
  ```bash
  cd ~/proxmox-lab/terraform
  terraform plan
  ```
  - 意図しない差分がないことを確認

- [ ] Velero リストアのテスト (テスト namespace で実施)
  ```bash
  velero restore create test-restore --from-backup <backup-name> --include-namespaces test
  ```

- [ ] PBS バックアップからの復元テスト (非本番 VM で実施)

### 確認結果の記録

確認結果は特に問題があった場合に本リポジトリの Issue に記録し、対処を追跡する。
