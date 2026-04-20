# 自宅ラボ設計書 — 3ノード Proxmox クラスター

## 1. ハードウェア概要

### ノード仕様

| ホスト名 | 機種 | CPU | RAM | ストレージ | NIC |
|---------|------|-----|-----|-----------|-----|
| pve-node01 | NUC5i3RYH | Intel Core i3-5010U (2C/4T, 2.1GHz) | 16GB DDR3L | mSATA (OS) + 2.5" SATA (データ/ZFS) | Intel I218-V GbE × 1 |
| pve-node02 | NUC5i3RYH | Intel Core i3-5010U (2C/4T, 2.1GHz) | 16GB DDR3L | mSATA (OS) + 2.5" SATA (データ) | Intel I218-V GbE × 1 |
| pve-node03 | BOSGAME E2 | AMD Ryzen 5 3550H (4C/8T, 2.1GHz) | 32GB | SSD | GbE × 1 |

> 合計物理リソース: CPU 8C/16T, RAM 64GB

---

## 2. 自動化ハブ (Raspberry Pi 5)

| 項目 | 値 |
|------|-----|
| ホスト名 | raspberrypi5 |
| IP | 192.168.210.55/24 |
| MAC (eth0) | 2c:cf:67:b5:b2:be |
| OS | Ubuntu Server |

### 担当サービス

| サービス | 用途 |
|---------|------|
| dnsmasq | PXE 用 DHCP proxy + TFTP サーバー |
| nginx | Proxmox ISO コンテンツ・answer.toml 配信 |
| corosync-qnetd | クラスターのクォーラムデバイス |
| Ansible | Proxmox インストール後の構成管理 |
| Terraform + Packer | VM/CT プロビジョニング・テンプレートビルド |

---

## 3. ネットワーク設計

### 物理構成

```
[インターネット]
      |
   [ルーター/ONU]
      |
[L2マネージドスイッチ] ←── VLAN 設定
   |         |         |
[node01]  [node02]  [node03]
```

> 有線 NIC が 1 ポートのみのため、**マネージドスイッチによる VLAN タギング**で論理的にネットワークを分離する。

### VLAN 設計

| VLAN ID | 用途 | サブネット |
|---------|------|-----------|
| 1 (native) | 管理ネットワーク (Proxmox Web UI / SSH / k3s VM / 既存 LAN と共存) | 192.168.210.0/24 |
| 20 | ストレージ / レプリケーション用 | 192.168.212.0/24 |

### ノード IPアドレス割り当て

| ホスト名 | 管理 IP (VLAN1) | ストレージ IP (VLAN20) |
|---------|----------------|----------------------|
| pve-node01 | 192.168.210.11/24 | 192.168.212.11/24 |
| pve-node02 | 192.168.210.12/24 | 192.168.212.12/24 |
| pve-node03 | 192.168.210.13/24 | — (ストレージ VLAN なし) |
| デフォルトゲートウェイ | 192.168.210.254 | — |

> NIC 1本でも Linux Bridge + VLAN サブインターフェース (`vmbr0.20`) により分離可能。
> 管理 VLAN は既存の LAN (このPC: `192.168.210.81`) と同一セグメントのため、PC から直接 Web UI (`:8006`) へアクセス可能。
> k3s VM も管理 VLAN (192.168.210.0/24) に配置するため、クロスノードルーティング不要。

---

## 3. ソフトウェアスタック

### 基盤

| レイヤー | 採用技術 | バージョン目安 |
|---------|---------|--------------|
| ハイパーバイザー | Proxmox VE | 8.x (Debian 12 Bookworm ベース) |
| 仮想化 | KVM + QEMU | Proxmox 同梱版 |
| コンテナ | LXC | Proxmox 同梱版 |
| クラスタリング | Corosync + Pacemaker | Proxmox 同梱版 |
| クォーラム | Corosync QDevice | 外部 QDevice (後述) |

### ストレージ

| 用途 | 技術 | 備考 |
|------|------|------|
| OS領域 | ext4 (mSATA) | Proxmox インストーラーデフォルト |
| VM/CT ローカルストレージ | ZFS (RAID なし / mirror 検討) | 各ノードの 2.5" SSD |
| VM レプリケーション | Proxmox Replication (ZFS スナップショット差分転送) | node01 ↔ node02 |
| バックアップ | Proxmox Backup Server (PBS) | 別途 VM or 外付け HDD |

> Ceph は 3 ノードで導入可能だが、現時点では未実装。ZFS + Proxmox Replication で擬似的な HA ストレージを実現する。

---

## 4. クラスター クォーラム設計

3 ノードクラスターではノード過半数 (2/3) で自律的にクォーラムを維持できるが、1 ノード障害時に残り 2 ノードが均等分割される状況を防ぐため、引き続き **QDevice (Corosync Quorum Device)** を設置している。

### QDevice の設置先候補

| 選択肢 | コスト | 難易度 | 備考 |
|--------|--------|--------|------|
| Raspberry Pi (推奨) | 低 | 低 | 常時稼働・低消費電力 |
| 安価な VPS | 月数百円 | 中 | インターネット経由 |
| 既存 PC の LXC コンテナ | 無料 | 中 | 同一ラック内は好ましくない |

### QDevice セットアップコマンド概要

```bash
# QDevice ホスト (Raspberry Pi 等) にパッケージインストール
apt install corosync-qnetd

# Proxmox ノード側でクラスター作成後に QDevice 追加
pvecm qdevice setup <qdevice-ip>
```

---

## 5. 高可用性 (HA) 設計

### HA グループ設定

```
HA グループ: homelab-ha
  メンバー: pve-node01 (priority=2), pve-node02 (priority=1), pve-node03 (priority=1)
  制約: nofailback=0 (フェイルバックあり)
```

### フェイルオーバー動作

1. node01 障害検知 (Watchdog / `fence_ipmilan` 等)
2. STONITH によるノード隔離 (必要に応じて)
3. HA VM が node02 へ自動マイグレーション
4. Proxmox Replication で同期済みの ZFS スナップショットから起動

> NUC は IPMI 非搭載のため、STONITH は**ソフトウェアフェンシング** (`fence_virsh` や電源制御可能スマートプラグ) で代替する。

---

## 6. 仮想マシン / コンテナ 運用計画

### 現在の VM / CT 構成

| 名前 | VM ID | 種別 | vCPU | RAM | ノード | 用途 |
|------|-------|------|------|-----|--------|------|
| dns-ct | 101 | LXC | 1 | 512MB | pve-node01 | Pi-hole (内部 DNS) |
| k3s-master | 201 | VM | 2 | 6GB | pve-node01 | k3s コントロールプレーン |
| k3s-worker03 | 204 | VM | 1 | 4GB | pve-node02 | k3s ワーカー |
| k3s-worker04 | 205 | VM | 1 | 4GB | pve-node02 | k3s ワーカー |
| k3s-worker05 | 206 | VM | 1 | 4GB | pve-node02 | k3s ワーカー |
| k3s-worker06 | 207 | VM | 2 | 8GB | pve-node03 | k3s ワーカー |
| k3s-worker07 | 208 | VM | 2 | 8GB | pve-node03 | k3s ワーカー |
| k3s-worker08 | 209 | VM | 2 | 8GB | pve-node03 | k3s ワーカー |

> worker01 (VM 202), worker02 (VM 203), worker09 (VM 210), worker10 (VM 211) は削除済み。
>
> リソース合計: vCPU 13 / RAM 約 46.5GB — 3ノード合計 64GB 物理メモリの範囲内

### テンプレート管理

- Cloud-init 対応テンプレート (Ubuntu 22.04 / 24.04) を node01 に作成・保管
- `qm clone` でデプロイ、Cloud-init で SSH 鍵・IP を自動設定

---

## 7. バックアップ戦略

| 対象 | 方法 | 頻度 | 保持期間 |
|------|------|------|---------|
| 全 VM / CT | PBS (Proxmox Backup Server) スナップショット | 毎日 02:00 | 直近 7 世代 |
| 重要 VM | Proxmox Replication (増分転送) | 15 分ごと | — |
| 設定ファイル | Git (本リポジトリ) | 変更時 | 無制限 |

---

## 8. 監視・オブザーバビリティ

```
[Proxmox ノード (node_exporter)]
           |
    [Prometheus (monitoring-CT)]
           |
     [Grafana Dashboard]
```

- **Prometheus**: ノード・VM メトリクス収集
- **Grafana**: ダッシュボード可視化
- **Alertmanager**: 障害通知 (メール / LINE Notify / Slack)
- **Proxmox 組み込み**: Web UI のリソースグラフ、メール通知

---

## 9. セキュリティ設計

| 項目 | 対策 |
|------|------|
| SSH | パスワード認証無効・公開鍵認証のみ |
| Proxmox Web UI | ポート 8006 をファイアウォールで LAN に限定 |
| ユーザー管理 | root 直接ログイン禁止・PAM ユーザーで運用 |
| ファイアウォール | Proxmox 組み込み nftables ルールを有効化 |
| 証明書 | Let's Encrypt (ACME) で Web UI を HTTPS 化 |
| アップデート | `unattended-upgrades` でセキュリティパッチ自動適用 |

---

## 10. 構築手順 概要

```
[Phase 1] ハードウェア準備
  ├── RAM 16GB × 2 / SSD (mSATA + 2.5") 取り付け
  └── BIOS: VT-x 有効化・Wake on LAN 有効化

[Phase 2] Proxmox VE インストール
  ├── node01, node02, node03 それぞれに Proxmox VE 8.x インストール
  ├── 静的 IP 設定 / ホスト名設定
  └── VLAN サブインターフェース設定

[Phase 3] クラスター構築
  ├── node01 でクラスター作成: pvecm create homelab
  ├── node02, node03 をクラスターに参加: pvecm add 192.168.210.11
  └── QDevice セットアップ

[Phase 4] ストレージ設定
  ├── 各ノードで ZFS プール作成 (2.5" SSD)
  └── Proxmox Replication ジョブ設定

[Phase 5] VM / CT デプロイ
  ├── Cloud-init テンプレート作成
  ├── 基本サービス (DNS, 監視) デプロイ
  └── k3s クラスター構築

[Phase 6] HA / バックアップ設定
  ├── PBS セットアップ
  ├── バックアップジョブ設定
  └── HA グループ・リソース設定
```

---

## 11. 将来の拡張案

- **Ceph 導入**: 3 ノード揃ったため導入可能。ただし NUC のディスク帯域・NIC 1 本がボトルネックになる点は要検討
- **10GbE 化**: USB3.0→10GbE アダプター導入でストレージ転送速度向上
- **GPU パススルー**: pve-node03 (Ryzen 5 3550H) は IOMMU 対応のため Vega 8 iGPU パススルーを検討可能
- **SDN (Software Defined Network)**: Proxmox SDN でより複雑なネットワーク実験が可能

---

## 12. セットアップ手順・日常運用

### 初回セットアップ

| ステップ | ドキュメント | 内容 |
|---------|-------------|------|
| 1 | [scripts/README.md](../scripts/README.md) | Raspberry Pi セットアップ・Proxmox インストール |
| 2 | [ansible/README.md](../ansible/README.md) | Ansible でクラスター構築 |
| 3 | [packer/README.md](../packer/README.md) | Ubuntu VM テンプレートビルド |
| 4 | [terraform/README.md](../terraform/README.md) | VM / LXC コンテナデプロイ |

### 日常運用

| 操作 | コマンド |
|------|---------|
| ノード起動 | `bash scripts/proxmox-wakeup.sh` |
| クラスターシャットダウン | `ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/shutdown.yml` |
| Ansible 疎通確認 | `ansible -i ansible/inventory/hosts.yml proxmox -m ping` |

---

## 参考リンク

- [Proxmox VE 公式ドキュメント](https://pve.proxmox.com/pve-docs/)
- [Proxmox Corosync QDevice](https://pve.proxmox.com/wiki/Corosync_External_Vote_Support)
- [ZFS on Linux (OpenZFS)](https://openzfs.github.io/openzfs-docs/)
- [k3s 公式](https://k3s.io/)
