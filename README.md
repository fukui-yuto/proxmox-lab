# proxmox-lab

Intel NUC5i3RYH 2台を使った自宅ラボの構築リポジトリ。
Proxmox VE クラスターの構築から VM デプロイまでの手順と設定を管理する。

---

## 構成概要

```
[Raspberry Pi 5]  192.168.210.55
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

## 構築の流れ

| ステップ | 内容 | 手順 |
|---------|------|------|
| 1 | Raspberry Pi セットアップ・Proxmox インストール | [scripts/README.md](scripts/README.md) |
| 2 | Ansible でクラスター構築 | [ansible/README.md](ansible/README.md) |
| 3 | Packer で VM テンプレートをビルド | [packer/README.md](packer/README.md) |
| 4 | Terraform で VM / CT をデプロイ | [terraform/README.md](terraform/README.md) |
| 5 | k3s クラスターを構成 | [k8s/README.md](k8s/README.md) |
| 6 | Prometheus + Grafana をデプロイ | [k8s/monitoring/README.md](k8s/monitoring/README.md) |

日常運用 (起動・シャットダウン) は [docs/runbook.md](docs/runbook.md) を参照。

---

## リポジトリ構成

```
proxmox-lab/
├── docs/
│   ├── design.md               # 設計書
│   └── runbook.md              # 日常運用 (起動・シャットダウン)
├── scripts/
│   ├── README.md               # ★ Step 1: Raspberry Pi セットアップ手順
│   ├── raspi-setup.sh          # Raspberry Pi 一括セットアップ
│   └── proxmox-wakeup.sh       # Proxmox ノード Wake-on-LAN 起動
├── ansible/
│   ├── README.md               # ★ Step 2: クラスター構築手順
│   ├── inventory/hosts.yml     # ノード定義
│   └── playbooks/
│       ├── site.yml            # 全体実行エントリポイント
│       └── shutdown.yml        # クラスター安全シャットダウン
├── packer/
│   ├── README.md               # ★ Step 3: テンプレートビルド手順
│   └── ubuntu-2404.pkr.hcl    # Ubuntu 24.04 テンプレート定義
├── terraform/
│   ├── README.md               # ★ Step 4: VM/CT デプロイ手順
│   ├── main.tf                 # VM / LXC コンテナ定義
│   └── variables.tf
└── k8s/
    ├── README.md               # ★ Step 5: k3s クラスター構成手順
    └── monitoring/
        ├── README.md           # ★ Step 6: Prometheus + Grafana
        └── values.yaml
```

---

## デプロイされる VM / コンテナ

| 名前 | 種別 | IP | 用途 |
|------|------|----|------|
| k3s-master | VM | 192.168.211.21 | k3s マスター (pve-node01) |
| k3s-worker01 | VM | 192.168.211.22 | k3s ワーカー (pve-node01) |
| k3s-worker02 | VM | 192.168.211.23 | k3s ワーカー (pve-node01) |
| k3s-worker03 | VM | 192.168.211.24 | k3s ワーカー (pve-node02) |
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
