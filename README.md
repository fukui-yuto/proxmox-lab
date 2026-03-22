# proxmox-lab

Intel NUC5i3RYH 2台を使った自宅ラボの構築リポジトリ。
Proxmox VE クラスターの構築から VM デプロイまで全工程を自動化する。

---

## 構成概要

```
[Raspberry Pi 5]  192.168.210.55
  ├── PXE サーバー     → NUC に Proxmox を自動インストール
  ├── corosync-qnetd  → 2ノードクラスターのクォーラム
  └── Ansible / Terraform / Packer 実行環境

[pve-node01]  192.168.210.11  (NUC5i3RYH)
[pve-node02]  192.168.210.12  (NUC5i3RYH)
  └── Proxmox VE 8.x クラスター "homelab"
```

## ネットワーク

| VLAN | 用途 | サブネット |
|------|------|-----------|
| 1 (native) | 管理 / 既存 LAN | 192.168.210.0/24 |
| 10 | VM / コンテナ通信 | 192.168.211.0/24 |
| 20 | ストレージ / レプリケーション | 192.168.212.0/24 |

---

## リポジトリ構成

```
proxmox-lab/
├── design.md                   # 設計書
├── install/
│   ├── answer-node01.toml      # Proxmox 無人インストール設定 (node01)
│   └── answer-node02.toml      # Proxmox 無人インストール設定 (node02)
├── raspi/
│   ├── README.md               # Raspberry Pi 操作手順書
│   ├── setup.sh                # Raspberry Pi 一括セットアップ
│   ├── dnsmasq/pxe.conf        # PXE DHCP proxy 設定
│   ├── grub/grub.cfg           # PXE ブートメニュー (MAC で振り分け)
│   └── nginx/pve-install.conf  # ISO / answer.toml 配信設定
├── ansible/
│   ├── inventory/hosts.yml     # ノード定義
│   └── playbooks/
│       ├── site.yml            # 全体実行エントリポイント
│       ├── 01-base.yml         # 共通設定・SSH 強化
│       ├── 02-cluster.yml      # クラスター構築・QDevice
│       ├── 03-storage.yml      # ZFS プール作成
│       └── 04-network.yml      # VLAN Bridge 設定
├── terraform/
│   ├── main.tf                 # VM / LXC コンテナ定義
│   └── variables.tf
└── packer/
    ├── ubuntu-2404.pkr.hcl     # Ubuntu 24.04 テンプレートビルド
    └── http/user-data.yml      # Ubuntu autoinstall 設定
```

---

## 構築の流れ

```
Step 1: Raspberry Pi セットアップ
         └── raspi/setup.sh を実行

Step 2: answer.toml を編集
         └── root パスワード・SSH 公開鍵・ディスク名を設定

Step 3: NUC を PXE ブート
         └── Proxmox VE が自動インストールされる

Step 4: Ansible でクラスター構築
         └── ansible-playbook playbooks/site.yml

Step 5: Packer で VM テンプレートをビルド
         └── packer build packer/ubuntu-2404.pkr.hcl

Step 6: Terraform で VM / CT をデプロイ
         └── terraform apply
```

詳細な手順は [raspi/README.md](raspi/README.md) を参照。

---

## デプロイされる VM / コンテナ

| 名前 | 種別 | IP | 用途 |
|------|------|----|------|
| k3s-master | VM | 192.168.211.21 | k3s マスター |
| k3s-worker01 | VM | 192.168.211.22 | k3s ワーカー |
| k3s-worker02 | VM | 192.168.211.23 | k3s ワーカー |
| dns-ct | LXC | 192.168.210.53 | Pi-hole (DNS) |

---

## 使用技術

| カテゴリ | 技術 |
|---------|------|
| ハイパーバイザー | [Proxmox VE 8.x](https://www.proxmox.com/) |
| OS | Debian 12 (Proxmox 基盤) / Ubuntu 24.04 (VM) |
| ストレージ | ZFS + Proxmox Replication |
| クォーラム | Corosync QDevice |
| 構成管理 | Ansible |
| インフラ管理 | Terraform ([bpg/proxmox](https://registry.terraform.io/providers/bpg/proxmox)) |
| テンプレート | Packer |
| PXE | dnsmasq + nginx |
