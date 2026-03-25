# ansible/

Proxmox クラスターの構築・管理 Playbook。

```
ansible/
├── inventory/
│   └── hosts.yml       # ノード一覧・接続設定
└── playbooks/
    ├── 00-bootstrap.yml  # SSH 鍵配布 (初回のみ)
    ├── 01-base.yml       # リポジトリ・SSH 強化・hosts 設定
    ├── 02-cluster.yml    # クラスター作成・QDevice 追加
    ├── 03-storage.yml    # ZFS プール作成
    ├── 04-network.yml    # VLAN Bridge 設定
    ├── site.yml          # 01〜04 を一括実行
    └── shutdown.yml      # クラスター安全シャットダウン
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
| `04-network.yml` | VLAN Bridge (vmbr0.10 / vmbr0.20) 設定 |

### クラスター確認

```bash
ssh root@192.168.210.11 pvecm status
```

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
