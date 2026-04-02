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
    ├── site.yml                  # 01〜05-raspi を一括実行
    └── shutdown.yml              # クラスター安全シャットダウン
```

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

両ノードから `pong` が返れば OK。

### 全手順を一括実行

```bash
ansible-playbook -i inventory/hosts.yml playbooks/site.yml
```

| Playbook | 内容 |
|---------|------|
| `01-base.yml` | リポジトリ設定・SSH 強化・hosts 設定 |
| `02-cluster.yml` | クラスター作成・node02 参加・QDevice 追加 |
| `03-storage.yml` | ZFS プール作成・Proxmox ストレージ登録 |
| `04-network.yml` | Linux Bridge (vmbr0 / vmbr0.20) 設定 |
| `05-raspi-network.yml` | Raspberry Pi の静的 IP 設定 |

### クラスター確認

```bash
ssh root@192.168.210.11 pvecm status
```

---

## クラスター安定性向上 (無線切断対策)

子機ルーター経由の無線接続が一時的に切断されてもクォーラムを維持・自動復旧させる設定。

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

## クラスターのシャットダウン

`shutdown.yml` は全 VM を停止してから node02 → node01 の順で安全にシャットダウンする。

```bash
# 確認プロンプトあり
ansible-playbook -i inventory/hosts.yml playbooks/shutdown.yml

# 確認をスキップ
ansible-playbook -i inventory/hosts.yml playbooks/shutdown.yml -e confirm=yes
```

> 起動は `scripts/proxmox-wakeup.sh` を使用する。詳細は `scripts/README.md` を参照。

---

## トラブルシューティング

### ZFS プール作成に失敗する場合

```bash
ssh root@192.168.210.11 lsblk
```

デバイス名が異なる場合は `inventory/hosts.yml` の `zfs_data_disk` を修正する。
