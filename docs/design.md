# 自宅ラボ設計書 — 2ノード Proxmox クラスター

## 1. ハードウェア概要

### ノード仕様 (NUC5i3RYH × 2)

| 項目 | 仕様 |
|------|------|
| CPU | Intel Core i3-5010U (2C/4T, 2.1GHz, Broadwell) |
| RAM | 最大 16GB DDR3L SO-DIMM (スロット×2) |
| ストレージ | mSATA (OS用) + 2.5" SATA (データ用) |
| NIC | Intel I218-V GbE × 1 (有線) + Intel AC-7265 (Wi-Fi, 非推奨) |
| 映像出力 | HDMI + Mini DisplayPort |
| USB | USB 3.0 × 4 |
| 消費電力 | アイドル時 約5〜10W |

### 推奨メモリ・ストレージ構成

| ノード | mSATA (OS) | 2.5" SATA (データ) | RAM |
|--------|-----------|-------------------|-----|
| node01 | 32〜64GB SSD | 256GB〜1TB SSD | 16GB |
| node02 | 32〜64GB SSD | 256GB〜1TB SSD | 16GB |

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
| corosync-qnetd | 2ノードクラスターのクォーラムデバイス |
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
   |         |
[node01]  [node02]
```

> NUC5i3RYH は有線 NIC が 1 ポートのみのため、**マネージドスイッチによる VLAN タギング**で論理的にネットワークを分離する。

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
| Proxmox VIP (任意) | 192.168.210.10/24 | — |
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

> **Ceph は 3 ノード以上推奨のため採用しない。**
> ZFS + Proxmox Replication で擬似的な HA ストレージを実現する。

---

## 4. クラスター クォーラム設計

2 ノードクラスターは Split-Brain が発生しやすいため、**QDevice (Corosync Quorum Device)** を必須とする。

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
  メンバー: pve-node01 (priority=2), pve-node02 (priority=1)
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

### ワークロード例

| 名前 | 種別 | vCPU | RAM | 用途 |
|------|------|------|-----|------|
| router-vm | VM (Alpine) | 1 | 512MB | ソフトウェアルーター (VyOS / pfSense 検討) |
| dns-ct | LXC | 1 | 256MB | Pi-hole (広告ブロック / 内部 DNS) |
| k3s-master | VM (Ubuntu) | 1 | 1GB | k3s マスターノード |
| k3s-worker01 | VM (Ubuntu) | 1 | 1GB | k3s ワーカー |
| k3s-worker02 | VM (Ubuntu) | 1 | 1GB | k3s ワーカー |
| monitoring | LXC | 1 | 512MB | Prometheus + Grafana |
| pbs | VM (Debian) | 1 | 1GB | Proxmox Backup Server |

> リソース合計: vCPU 10 / RAM 約 9GB — 2ノード × 4スレッド・16GB の範囲内に収まる設計

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
  ├── node01, node02 それぞれに Proxmox VE 8.x インストール
  ├── 静的 IP 設定 / ホスト名設定
  └── VLAN サブインターフェース設定

[Phase 3] クラスター構築
  ├── node01 でクラスター作成: pvecm create homelab
  ├── node02 をクラスターに参加: pvecm add 192.168.10.11
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

- **ノード追加**: 3 台目の NUC 追加で Ceph 導入が可能になり、真の分散ストレージを実現
- **10GbE 化**: USB3.0→10GbE アダプター導入でストレージ転送速度向上
- **GPU パススルー**: 非対応 (i3-5010U は VT-d なし / IOMMU グループ制限あり)
- **SDN (Software Defined Network)**: Proxmox SDN でより複雑なネットワーク実験が可能

---

## 参考リンク

- [Proxmox VE 公式ドキュメント](https://pve.proxmox.com/pve-docs/)
- [Proxmox Corosync QDevice](https://pve.proxmox.com/wiki/Corosync_External_Vote_Support)
- [ZFS on Linux (OpenZFS)](https://openzfs.github.io/openzfs-docs/)
- [k3s 公式](https://k3s.io/)
