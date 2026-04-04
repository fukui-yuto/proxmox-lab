# proxmox-lab

Intel NUC5i3RYH 2台 + BOSGAME E2 1台を使った自宅ラボの構築リポジトリ。
Proxmox VE クラスターの構築から VM デプロイまでの手順と設定を管理する。

---

## 構成概要

```
[Raspberry Pi 5]  192.168.210.55
  ├── corosync-qnetd  → 2ノードクラスターのクォーラム
  └── Ansible / Terraform / Packer 実行環境

[pve-node01]  192.168.210.11  (NUC5i3RYH / Intel Core i3-5010U / 16GB RAM)
[pve-node02]  192.168.210.12  (NUC5i3RYH / Intel Core i3-5010U / 16GB RAM)
[pve-node03]  192.168.210.13  (BOSGAME E2 / AMD Ryzen 5 3550H / 32GB RAM)
  └── Proxmox VE 8.x クラスター "homelab"
```

## ネットワーク

| VLAN | 用途 | サブネット |
|------|------|-----------|
| 1 (native) | 管理 / VM / 既存 LAN | 192.168.210.0/24 |
| 20 | ストレージ / レプリケーション | 192.168.212.0/24 |

---

## 構築の流れ

| ステップ | 内容 | 手順 |
|---------|------|------|
| 1 | Raspberry Pi セットアップ・Proxmox インストール | [scripts/README.md](scripts/README.md) |
| 2 | Ansible でクラスター構築 | [ansible/README.md](ansible/README.md) |
| 3 | Packer で VM テンプレートをビルド | [packer/README.md](packer/README.md) |
| 4 | Terraform で VM デプロイ・k3s クラスター構成 | [terraform/README.md](terraform/README.md) |
| 5 | ArgoCD で k8s アプリをデプロイ | [k8s/argocd/README.md](k8s/argocd/README.md) |

日常運用 (起動・シャットダウン) は [power/README.md](power/README.md) を参照。

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
│       ├── 01-base.yml         # リポジトリ・SSH 強化・hosts 設定
│       ├── 02-cluster.yml      # クラスター作成・QDevice 追加
│       ├── 03-storage.yml      # ZFS プール作成
│       ├── 04-network.yml      # VLAN Bridge 設定
│       ├── 06-resilience.yml   # クラスター安定化
│       └── 08-nic-tuning.yml   # pve-node01 e1000e NIC チューニング
├── packer/
│   ├── README.md               # ★ Step 3: テンプレートビルド手順
│   └── ubuntu-2404.pkr.hcl    # Ubuntu 24.04 テンプレート定義
├── terraform/
│   ├── README.md               # ★ Step 4: VM/CT デプロイ手順
│   ├── main.tf                 # VM / LXC コンテナ定義
│   └── variables.tf
├── k8s/
│   ├── README.md               # k3s 上へのアプリデプロイ手順
│   ├── argocd/                 # ★ Step 5: GitOps 管理 (全アプリの起点)
│   ├── monitoring/             # Prometheus + Grafana (常時起動)
│   ├── logging/                # Elasticsearch + Fluent Bit + Kibana (常時起動)
│   ├── kyverno/                # ポリシーエンジン (常時起動)
│   ├── vault/                  # シークレット管理 (オンデマンド)
│   ├── harbor/                 # コンテナレジストリ (オンデマンド)
│   ├── keycloak/               # SSO / 認証基盤 (オンデマンド)
│   └── tracing/                # 分散トレーシング (オンデマンド)
└── power/
    ├── README.md               # クラスター起動・シャットダウン手順
    ├── scripts/                # 自動起動・停止スクリプト
    └── ansible/                # シャットダウン Playbook
```

---

## デプロイされる VM / コンテナ

| 名前 | 種別 | IP | 用途 |
|------|------|----|------|
| k3s-master | VM | 192.168.210.21 | k3s マスター (pve-node01) |
| k3s-worker01 | VM | 192.168.210.22 | k3s ワーカー (pve-node01) |
| k3s-worker03 | VM | 192.168.210.24 | k3s ワーカー (pve-node02) |
| k3s-worker04 | VM | 192.168.210.25 | k3s ワーカー (pve-node02) |
| k3s-worker05 | VM | 192.168.210.26 | k3s ワーカー (pve-node02) |
| k3s-worker06 | VM | 192.168.210.27 | k3s ワーカー (pve-node03) |
| k3s-worker07 | VM | 192.168.210.28 | k3s ワーカー (pve-node03) |
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
