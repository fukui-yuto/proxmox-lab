# Raspberry Pi セットアップ手順書

**対象マシン**: Raspberry Pi 5 (`192.168.210.55`)
**OS**: Ubuntu Server

---

## 目次

1. [事前準備](#1-事前準備)
2. [SSH 鍵の生成・配置](#2-ssh-鍵の生成配置)
3. [リポジトリのクローン](#3-リポジトリのクローン)
4. [answer.toml の編集](#4-answertoml-の編集)
5. [セットアップスクリプトの実行](#5-セットアップスクリプトの実行)
6. [動作確認](#6-動作確認)
7. [NUC の PXE インストール](#7-nuc-の-pxe-インストール)
8. [Ansible によるクラスター構築](#8-ansible-によるクラスター構築)
9. [Terraform による VM デプロイ](#9-terraform-による-vm-デプロイ)

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

## 2. SSH 鍵の生成・配置

Raspberry Pi 上で SSH 鍵ペアを生成する。
この鍵を NUC (Proxmox) と Ansible の接続に使用する。

```bash
ssh-keygen -t ed25519 -C "homelab" -f ~/.ssh/id_ed25519
```

公開鍵を確認しておく（後で `answer.toml` に貼り付ける）。

```bash
cat ~/.ssh/id_ed25519.pub
```

出力例:
```
ssh-ed25519 AAAA... homelab
```

---

## 3. リポジトリのクローン

```bash
git clone https://github.com/fukui-yuto/proxmox-lab.git ~/proxmox-lab
cd ~/proxmox-lab
```

---

## 4. answer.toml の編集

NUC に Proxmox を無人インストールするための設定ファイルを編集する。
**node01 と node02 それぞれ**編集すること。

### node01

```bash
nano ~/proxmox-lab/install/answer-node01.toml
```

編集箇所:

| 項目 | 設定値 |
|------|--------|
| `root_password` | 任意の root パスワードに変更 |
| `root_ssh_keys` | 手順2で確認した公開鍵を貼り付け |
| `disk_list` | NUC の mSATA デバイス名 (後述) |

```toml
root_password = "ここを変更"
root_ssh_keys = [
  "ssh-ed25519 AAAA...  ← 手順2の公開鍵をここに貼り付け"
]
```

### node02

```bash
nano ~/proxmox-lab/install/answer-node02.toml
```

`root_password` と `root_ssh_keys` を node01 と同じ値に変更する。

### mSATA デバイス名の確認方法

NUC に Ubuntu Live USB などを挿して起動し、以下を実行する。

```bash
lsblk -d -o NAME,SIZE,TYPE
```

出力例:
```
NAME   SIZE TYPE
sda     32G disk   ← mSATA (OS インストール先)
sdb    256G disk   ← 2.5" SSD (データ用)
```

`disk_list` には mSATA のデバイス (`/dev/sda` など) を指定する。

---

## 5. セットアップスクリプトの実行

以下のコマンドで必要なサービスを一括インストール・設定する。

```bash
cd ~/proxmox-lab
sudo bash raspi/setup.sh
```

スクリプトが行う処理:

- `dnsmasq` のインストール・PXE 設定の適用
- `nginx` のインストール・ファイル配信設定の適用
- Proxmox VE ISO のダウンロードと展開 (`/srv/pxe/iso/`)
- `install/answer-*.toml` を `/srv/pxe/answer/` にコピー
- `corosync-qnetd` の有効化
- `ansible`, `terraform`, `packer` のインストール

> **注意**: setup.sh 実行後に answer.toml を再編集した場合は、手動で再コピーすること。
> ```bash
> sudo cp ~/proxmox-lab/install/answer-node01.toml /srv/pxe/answer/node01.toml
> sudo cp ~/proxmox-lab/install/answer-node02.toml /srv/pxe/answer/node02.toml
> ```

> 所要時間: ISO ダウンロード込みで 10〜20 分程度

完了後、各サービスの状態を確認する。

```bash
sudo systemctl status dnsmasq
sudo systemctl status nginx
sudo systemctl status corosync-qnetd
```

すべて `active (running)` になっていれば OK。

---

## 6. 動作確認

### PXE ファイル配信確認

このPC のブラウザで以下にアクセスし、ファイル一覧が表示されることを確認する。

```
http://192.168.210.55/iso/
http://192.168.210.55/answer/
```

### answer.toml 確認

```bash
curl http://192.168.210.55/answer/node01.toml
curl http://192.168.210.55/answer/node02.toml
```

内容が表示されれば OK。

### dnsmasq ログ確認

NUC を起動したときに PXE リクエストが来ているか確認する。

```bash
sudo journalctl -u dnsmasq -f
```

---

## 7. NUC の PXE インストール

### BIOS 設定 (NUC 2台とも)

1. NUC の電源を入れ `F2` を連打して BIOS に入る
2. **Boot Order** で `Network Boot (LAN)` を最優先に設定
3. **Advanced → Boot → UEFI Boot** が有効になっていることを確認
4. 設定を保存して再起動 (`F10`)

### インストール実行

NUC の電源を入れると自動的に以下が進む。

```
NUC 起動
  └─ PXE ブート (dnsmasq が IP を払い出し)
       └─ GRUB が MAC アドレスを識別
            └─ answer.toml を取得
                 └─ Proxmox VE 自動インストール開始
                      └─ インストール完了 → 自動再起動
```

> 所要時間: 約 5〜10 分

### インストール完了確認

Raspberry Pi 側でログを確認する。

```bash
sudo tail -f /var/log/nginx/pxe-done.log
```

`POST /webhook/done` が記録されれば完了。

このPCのブラウザで Proxmox Web UI にアクセスできることを確認する。

```
https://192.168.210.11:8006   ← node01
https://192.168.210.12:8006   ← node02
```

---

## 8. Ansible によるクラスター構築

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
Total votes:      3    ← QDevice 込みで 3 票
Quorum:           2
```

---

## 9. Terraform による VM デプロイ

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

## トラブルシューティング

### PXE ブートしない場合

- NUC の BIOS で Network Boot が有効か確認
- `sudo journalctl -u dnsmasq -f` でリクエストが届いているか確認
- ルーターの DHCP と競合していないか確認

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
