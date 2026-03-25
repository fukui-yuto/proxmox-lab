# scripts/

Raspberry Pi セットアップと Proxmox ノードの起動スクリプト。

---

## 目次

1. [事前準備](#1-事前準備)
2. [SSH 鍵の確認](#2-ssh-鍵の確認)
3. [リポジトリのクローン](#3-リポジトリのクローン)
4. [セットアップスクリプトの実行](#4-セットアップスクリプトの実行)
5. [動作確認](#5-動作確認)
6. [NUC への Proxmox VE 手動インストール (USB ブート)](#6-nuc-への-proxmox-ve-手動インストール-usb-ブート)
7. [Proxmox ノードの起動 (Wake-on-LAN)](#7-proxmox-ノードの起動-wake-on-lan)

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

ログイン: `root` / 手順 6-3 で設定したパスワード

### 6-5. SSH 公開鍵の登録 (Raspberry Pi から実施)

Ansible が SSH で接続できるよう、bootstrap playbook で自動登録する。

```bash
cd ~/proxmox-lab/ansible

# sshpass が必要 (初回のみ)
apt install sshpass

# PVE の root パスワードを入力して SSH 鍵を配布
ansible-playbook playbooks/00-bootstrap.yml -k
```

接続確認:

```bash
ansible -i inventory/hosts.yml proxmox -m ping
```

---

## 7. Proxmox ノードの起動 (Wake-on-LAN)

`proxmox-wakeup.sh` を使って Proxmox ノードを起動する。

### 事前準備

**1. BIOS で WoL を有効化 (NUC5i3RYH の場合)**

1. 起動時に `F2` → BIOS Setup
2. **Advanced → Power → Secondary Power Settings**
3. **"Wake-on-LAN from S4/S5"** を **"Power On - Normal Boot"** に設定
4. `F10` で保存

**2. Proxmox OS 側で WoL を有効化**

```bash
# インターフェース名確認
ip link show

# WoL 有効化 (enp0s25 は実際のIF名に置換)
ethtool -s enp0s25 wol g

# 永続化
echo "post-up ethtool -s enp0s25 wol g" >> /etc/network/interfaces
```

**3. MAC アドレスを確認してスクリプトに記入**

```bash
# Proxmox ノード上で実行
ip link show
```

`proxmox-wakeup.sh` 先頭の `NODE01_MAC` / `NODE02_MAC` に記入する。

**4. `wakeonlan` コマンドをインストール**

```bash
# Raspberry Pi (Ubuntu) の場合
apt install wakeonlan
```

### 使い方

```bash
# 両ノードを起動
bash scripts/proxmox-wakeup.sh

# node01 のみ
bash scripts/proxmox-wakeup.sh node01

# node02 のみ
bash scripts/proxmox-wakeup.sh node02
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
