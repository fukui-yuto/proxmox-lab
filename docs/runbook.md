# Raspberry Pi セットアップ手順書

**対象マシン**: Raspberry Pi 5 (`192.168.210.55`)
**OS**: Ubuntu Server

---

## 目次

1. [事前準備](#1-事前準備)
2. [SSH 鍵の確認](#2-ssh-鍵の確認)
3. [リポジトリのクローン](#3-リポジトリのクローン)
4. [セットアップスクリプトの実行](#4-セットアップスクリプトの実行)
5. [動作確認](#5-動作確認)
6. [NUC への Proxmox VE 手動インストール (USB ブート)](#6-nuc-への-proxmox-ve-手動インストール-usb-ブート)
7. [Ansible によるクラスター構築](#7-ansible-によるクラスター構築)
8. [Terraform による VM デプロイ](#8-terraform-による-vm-デプロイ)

---

## 1. 事前準備

このPCから Raspberry Pi に SSH で接続する。

```bash
ssh yuto@192.168.210.55
```

パッケージを最新にしておく。

```bash
sudo apt-get update && sudo apt-get upgrade -y
```

---

## 2. SSH 鍵の確認

Raspberry Pi 上の SSH 鍵を NUC (Proxmox) と Ansible の接続に使用する。

既に `id_ed25519` が存在するか確認する。

```bash
ls ~/.ssh/id_ed25519.pub
```

**存在する場合はそのまま使用する。** 公開鍵の内容だけ確認しておく。

```bash
cat ~/.ssh/id_ed25519.pub
```

**存在しない場合のみ**新規生成する。

```bash
ssh-keygen -t ed25519 -C "homelab" -f ~/.ssh/id_ed25519
```

> 公開鍵はセクション6-5で各 NUC に `ssh-copy-id` で登録する。

---

## 3. リポジトリのクローン

```bash
git clone https://github.com/fukui-yuto/proxmox-lab.git ~/proxmox-lab
cd ~/proxmox-lab
```

---

## 4. セットアップスクリプトの実行

以下のコマンドで必要なサービスを一括インストール・設定する。

```bash
cd ~/proxmox-lab
sudo bash scripts/raspi-setup.sh
```

スクリプトが行う処理:

- `corosync-qnetd` のインストール・有効化
- `ansible`, `terraform`, `packer` のインストール

> 所要時間: 約 5 分

完了後、サービスの状態を確認する。

```bash
sudo systemctl status corosync-qnetd
```

`active (running)` になっていれば OK。

---

## 5. 動作確認

### corosync-qnetd 確認

```bash
sudo systemctl status corosync-qnetd
```

### Ansible 疎通確認 (NUC インストール後に実施)

```bash
cd ~/proxmox-lab/ansible
ansible -i inventory/hosts.yml proxmox -m ping
```

両ノードから `pong` が返れば OK。

---

## 6. NUC への Proxmox VE 手動インストール (USB ブート)

### 6-1. USB インストールメディアの作成 (このPC で実施)

1. Proxmox VE の ISO を公式サイトからダウンロードする
   `https://www.proxmox.com/en/downloads` → **Proxmox VE 8.x ISO Installer**

2. [Rufus](https://rufus.ie/) または [Balena Etcher](https://etcher.balena.io/) で ISO を USB メモリに書き込む
   - Rufus の場合: パーティションスキーム = **GPT**、ターゲットシステム = **UEFI (CSM なし)**

### 6-2. BIOS 設定 (NUC 2台とも)

1. NUC に USB メモリを挿した状態で電源を入れ、`F2` を連打して BIOS に入る
2. **Boot Order** で `USB` を最優先に設定（Network Boot は無効にしてよい）
3. **Advanced → Boot → UEFI Boot** が有効になっていることを確認
4. 設定を保存して再起動 (`F10`)

### 6-3. インストール手順 (各 NUC で実施)

1. USB から起動すると Proxmox VE インストーラーが立ち上がる
2. **Install Proxmox VE (Graphical)** を選択
3. 使用許諾に同意して **Next**
4. **Target Harddisk**: mSATA SSD を選択 (通常 `/dev/sda`)
5. **Country / Timezone / Keyboard**: Japan / Asia/Tokyo / Japanese
6. **Password & Email**: root パスワードを設定、メールは適当でよい
7. **Network Configuration**:

   | 項目 | node01 | node02 |
   |------|--------|--------|
   | Management Interface | enp0s25 等 (有線 NIC) | 同左 |
   | Hostname (FQDN) | `pve-node01.local` | `pve-node02.local` |
   | IP Address | `192.168.210.11/24` | `192.168.210.12/24` |
   | Gateway | `192.168.210.254` | `192.168.210.254` |
   | DNS | `192.168.210.254` | `192.168.210.254` |

8. 内容を確認して **Install** → インストール完了後、USB を抜いて再起動

### 6-4. インストール完了確認

このPC のブラウザで Proxmox Web UI にアクセスできることを確認する。

```
https://192.168.210.11:8006   ← node01
https://192.168.210.12:8006   ← node02
```

ログイン: `root` / 手順 7-3 で設定したパスワード

### 6-5. SSH 公開鍵の登録 (Raspberry Pi から実施)

Ansible が SSH で接続できるよう、各ノードに Raspberry Pi の公開鍵を登録する。

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@192.168.210.11
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@192.168.210.12
```

接続確認:

```bash
ssh root@192.168.210.11 hostname
ssh root@192.168.210.12 hostname
```

---

## 7. Ansible によるクラスター構築

インストール完了後、Raspberry Pi から Ansible を実行してクラスターを自動構築する。

### 接続確認

```bash
cd ~/proxmox-lab/ansible
ansible -i inventory/hosts.yml proxmox -m ping
```

両ノードから `pong` が返れば OK。

### 全手順を一括実行

```bash
ansible-playbook -i inventory/hosts.yml playbooks/site.yml
```

実行される処理:

| Playbook | 内容 |
|---------|------|
| `01-base.yml` | リポジトリ設定・SSH 強化・hosts 設定 |
| `02-cluster.yml` | クラスター作成・node02 参加・QDevice 追加 |
| `03-storage.yml` | ZFS プール作成・Proxmox ストレージ登録 |
| `04-network.yml` | VLAN Bridge (vmbr0.10 / vmbr0.20) 設定 |

### クラスター確認

```bash
ssh root@192.168.210.11 pvecm status
```

出力例:
```
Cluster information
-------------------
Name:             homelab
Config Version:   2
Transport:        knet
Secure auth:      on

Quorum information
------------------
Date:             ...
Quorum provider:  corosync_votequorum
Nodes:            2
Node state:       connected

Votequorum information
----------------------
Expected votes:   3
Highest expected: 3
Total votes:      2    ← ノード票のみ (QDevice は Membership に別枠で表示)
Quorum:           2
```

---

## 8. Terraform による VM デプロイ

### Packer で Ubuntu テンプレートをビルド

```bash
cd ~/proxmox-lab/packer

packer init ubuntu-2404.pkr.hcl

packer build \
  -var "proxmox_password=<rootパスワード>" \
  -var "ssh_public_key=$(cat ~/.ssh/id_ed25519.pub)" \
  ubuntu-2404.pkr.hcl
```

完了すると Proxmox 上に VM ID `9000` のテンプレートが作成される。

### Terraform で VM/CT を作成

```bash
cd ~/proxmox-lab/terraform

terraform init

terraform apply \
  -var "proxmox_password=<rootパスワード>" \
  -var "ssh_public_key=$(cat ~/.ssh/id_ed25519.pub)" \
  -var "ct_root_password=<コンテナパスワード>"
```

作成されるリソース:

| リソース | ノード | IP |
|---------|--------|-----|
| k3s-master | pve-node01 | 192.168.211.21 |
| k3s-worker01 | pve-node01 | 192.168.211.22 |
| k3s-worker02 | pve-node02 | 192.168.211.23 |
| dns-ct (Pi-hole) | pve-node01 | 192.168.210.53 |

---

## 10. Proxmox Replication の設定 (手動・VM 作成後)

VM をデプロイした後、Proxmox Web UI から Replication を設定する。
これにより node01 ↔ node02 間で ZFS スナップショットが定期同期される。

1. `https://192.168.210.11:8006` にアクセス
2. 対象 VM を選択 → **Replication** タブ
3. **Add** をクリックして以下を設定する

| 項目 | 設定値 |
|------|--------|
| Target | もう一方のノード (pve-node02 等) |
| Schedule | `*/15` (15分ごと) |
| Rate limit | 空欄 (無制限) |

---

## 11. Terraform 用シークレットファイルの作成 (手動)

`terraform.tfvars` はパスワードを含むため Git 管理外。初回のみ手動で作成する。

```bash
cd ~/proxmox-lab/terraform
cp terraform.tfvars.example terraform.tfvars
nano terraform.tfvars
```

編集内容:

```hcl
proxmox_password = "Proxmox の root パスワード"
ssh_public_key   = "ssh-ed25519 AAAA..."  # cat ~/.ssh/id_ed25519.pub
ct_root_password = "LXC コンテナの root パスワード"
```

---

## 12. Packer 用パスワードハッシュの生成 (手動)

`packer/http/user-data.yml` の Ubuntu ユーザーパスワードはハッシュ形式で記述する。

```bash
# ハッシュを生成して出力
openssl passwd -6 "任意のパスワード"
```

出力されたハッシュを `user-data.yml` の該当箇所に貼り付ける:

```yaml
password: "$6$rounds=4096$xxxxxx..."  # ← ここに貼り付け
```

---

## トラブルシューティング

### Proxmox インストーラーが起動しない場合

- BIOS で USB Boot が有効か確認 (F2 → Boot Order)
- Rufus で書き込む場合: パーティションスキームを **GPT**、ターゲットシステムを **UEFI** に設定
- USB メモリを別のポートに挿し替えてみる

### Ansible が接続できない場合

```bash
# SSH 接続テスト
ssh -i ~/.ssh/id_ed25519 root@192.168.210.11

# known_hosts をリセット
ssh-keygen -R 192.168.210.11
```

### ZFS プール作成に失敗する場合

```bash
# ノードで直接確認
ssh root@192.168.210.11 lsblk
# /dev/sdb が見えているか確認
```

デバイス名が異なる場合は `ansible/playbooks/03-storage.yml` の `zfs_data_disk` を修正する。
