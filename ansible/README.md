# ansible/

Proxmox クラスターの構築・管理 Playbook。

```
ansible/
├── inventory/
│   └── hosts.yml                 # ノード一覧・接続設定
└── playbooks/
    ├── 00-bootstrap.yml          # SSH 鍵配布 (初回のみ)
    ├── 01-base.yml               # リポジトリ・SSH 強化・hosts 設定
    ├── 02-cluster.yml            # クラスター作成・QDevice 追加
    ├── 03-storage.yml            # ZFS プール作成
    ├── 04-network.yml            # VLAN Bridge 設定 (Proxmox ノード)
    ├── 05-raspi-network.yml      # Raspberry Pi 静的ルート設定
    ├── 06-resilience.yml         # クラスター安定化 (corosync + watchdog)
    ├── 07-proxmox-sdn.yml        # Proxmox SDN 設定 (参考・WebUI 推奨)
    └── site.yml                  # 01〜06 を一括実行
```

> シャットダウン関連のプレイブックは `power/ansible/` に移動しました。

---

## 初回セットアップ (SSH 鍵配布)

Ansible が SSH で接続できるよう、初回のみ実行する。

```bash
# sshpass が必要
apt install sshpass

# PVE の root パスワードを入力して SSH 鍵を配布
ansible-playbook -i inventory/hosts.yml playbooks/00-bootstrap.yml -k
```

---

## クラスター構築

### 接続確認

```bash
cd ~/proxmox-lab/ansible
ansible -i inventory/hosts.yml proxmox -m ping
```

全ノードから `pong` が返れば OK。

### 全手順を一括実行

```bash
ansible-playbook -i inventory/hosts.yml playbooks/site.yml
```

| Playbook | 内容 |
|---------|------|
| `01-base.yml` | リポジトリ設定・SSH 強化・hosts 設定 |
| `02-cluster.yml` | クラスター作成・node02/03 参加・QDevice 追加 |
| `03-storage.yml` | ZFS プール作成・Proxmox ストレージ登録 |
| `04-network.yml` | Linux Bridge (vmbr0 / vmbr0.20) 設定 |
| `05-raspi-network.yml` | Raspberry Pi の静的 IP 設定 |
| `06-resilience.yml` | クラスター安定化 (corosync タイムアウト延長・watchdog) |

### クラスター確認

```bash
ssh root@192.168.210.11 pvecm status
```

---

## クラスター安定性向上 (無線切断対策)

`site.yml` に含まれるため、一括実行で自動適用される。個別実行する場合は以下。

```bash
ansible-playbook -i inventory/hosts.yml playbooks/06-resilience.yml
```

| 対策 | 内容 |
|------|------|
| corosync token: 10000ms | 10秒以内の切断はクォーラム喪失なしに吸収 |
| qnetd watchdog (5分ごと) | 長期切断後にネットワーク復帰したら自動で qnetd を再起動 |

watchdog のログは Raspberry Pi の `/var/log/qnetd-watchdog.log` で確認できる。

---

## Proxmox SDN 設定

SDN の設定は **WebUI での実施を推奨**。`07-proxmox-sdn.yml` は確認・参考用。

```bash
# 現在の SDN 状態を確認するだけの場合
ansible-playbook -i inventory/hosts.yml playbooks/07-proxmox-sdn.yml --tags check

# SDN を自動設定する場合 (WebUI で設定済みなら不要)
ansible-playbook -i inventory/hosts.yml playbooks/07-proxmox-sdn.yml
```

詳細な手順は `docs/proxmox-sdn-guide.md` を参照。

---

## クラスターのシャットダウン・起動

シャットダウンおよび自動停止・起動スクリプトは `power/` ディレクトリで管理する。

```bash
# 手動シャットダウン (k8s drain なし)
ansible-playbook -i inventory/hosts.yml ../power/ansible/shutdown.yml

# 確認をスキップ
ansible-playbook -i inventory/hosts.yml ../power/ansible/shutdown.yml -e confirm=yes
```

> 自動停止・起動の詳細は `power/README.md` を参照。

---

## Wake-on-LAN (WoL)

全 Proxmox ノードの `nic0` で WoL (magic packet) を有効化している。

### 設定内容

`/etc/network/interfaces` の `nic0` stanza に以下が追加されている：

```
iface nic0 inet manual
    post-up ethtool -s nic0 wol g
```

起動時に自動で WoL が有効化される。

### 現在の WoL 状態を確認

```bash
ansible proxmox -i inventory/hosts.yml -m command -a "ethtool nic0" | grep "Wake-on"
```

| 表示 | 意味 |
|------|------|
| `Wake-on: g` | 有効 (magic packet) |
| `Wake-on: d` | 無効 |

### 設定を適用 (再適用時)

```bash
ansible-playbook -i inventory/hosts.yml playbooks/04-network.yml
```

---

## トラブルシューティング

### ZFS プール作成に失敗する場合

```bash
ssh root@192.168.210.11 lsblk
```

デバイス名が異なる場合は `inventory/hosts.yml` の `zfs_data_disk` を修正する。

### node03 が再起動後にクラスタへ参加できない (corosync config_version 不一致)

**症状**: node03 の corosync が起動直後に終了し、Proxmox UI でオフライン表示になる。

```
journalctl -u corosync | grep "config version"
# → Received config version (X) is different than my config version (Y)! Exiting
```

**原因**: node03 がオフライン中にクラスタ設定が変更され、`/etc/corosync/corosync.conf` のバージョンが古いまま残っている。

**対処**: node01 から正しい設定をコピーして corosync を再起動する。

```bash
scp /etc/corosync/corosync.conf root@192.168.210.13:/etc/corosync/corosync.conf
ssh root@192.168.210.13 systemctl restart corosync
```

**予防**: クラスタ設定を変更する際は全ノードをオンラインにした状態で行う。
