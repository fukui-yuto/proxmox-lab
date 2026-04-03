# power/

ラボの自動停止・起動スクリプトおよび Ansible プレイブック。

## ディレクトリ構成

```
power/
├── scripts/
│   ├── stop-lab.sh              # アイドル検知 + 自動停止 (pve-node01 で動作)
│   └── start-lab.sh             # ラボ起動 (Raspberry Pi から実行)
└── ansible/
    ├── setup-idle-shutdown.yml  # 初回セットアップ用プレイブック
    └── shutdown.yml             # 手動シャットダウン用プレイブック
```

---

## 動作概要

```
[stop-lab.sh: 5 分ごとに pve-node01 で実行]
  │
  ├─ アイドル判定 (全条件を満たすと +1)
  │    ├─ node01 CPU アイドル率 >= 95%
  │    ├─ node02 CPU アイドル率 >= 95%
  │    ├─ node03 CPU アイドル率 >= 95%
  │    ├─ vmbr0 ネットワーク <= 500 KB/s
  │    └─ pve-node01 へのログインセッション = 0
  │
  └─ 12 回連続アイドル (= 60 分) で停止シーケンス実行
       1. kubectl drain k3s-worker01〜07
       2. worker VM 停止 (202/203 on node01, 204/205/206 on node02, 207/208 on node03)
       3. k3s-master VM 停止 (201)
       4. dns-ct LXC 停止 (101)
       5. pve-node02 / pve-node03 poweroff
       6. pve-node01 poweroff (60 秒待機後)
```

---

## 初回セットアップ

### 1. Ansible プレイブックを実行

pve-node01 の SSH 公開鍵登録・スクリプトデプロイ・systemd timer の設定を一括で行う。

```bash
# ansible/ ディレクトリから実行すること (inventory/hosts.yml の場所が基準)
cd ~/proxmox-lab/ansible
ansible-playbook -i inventory/hosts.yml ../power/ansible/setup-idle-shutdown.yml
```

実行内容:
- pve-node01 の `/root/.ssh/id_rsa.pub` を k3s-master ubuntu ユーザーの `authorized_keys` に登録
- `stop-lab.sh` を pve-node01 の `/usr/local/lib/lab/stop-lab.sh` にデプロイ
- systemd timer (`lab-idle-shutdown.timer`) を有効化・起動

### 2. 動作確認

```bash
# timer の状態確認
ssh root@192.168.210.11 "systemctl status lab-idle-shutdown.timer"

# アイドルチェックを手動実行 (停止は行われない)
ssh root@192.168.210.11 "/usr/local/lib/lab/stop-lab.sh --dry-run"

# ログ確認
ssh root@192.168.210.11 "tail -f /var/log/lab-idle-shutdown.log"
```

---

## アイドル閾値のカスタマイズ

`power/scripts/stop-lab.sh` 冒頭の設定セクションで変更し、再度 Ansible を実行してデプロイする。

| 変数 | デフォルト | 説明 |
|------|-----------|------|
| `CPU_IDLE_THRESHOLD` | `95` | CPU アイドル率 (%) この値以上でアイドルとみなす |
| `NET_THRESHOLD_KB` | `500` | ネットワーク使用量 (KB/s) この値以下でアイドルとみなす |
| `NET_INTERFACE` | `vmbr0` | 監視するネットワークインターフェース |
| `REQUIRED_IDLE_CHECKS` | `12` | 連続回数 (× 5 分 = 停止までの時間) |
| `VM_SHUTDOWN_TIMEOUT` | `120` | VM 停止タイムアウト (秒) |

変更後の再デプロイ:

```bash
cd ~/proxmox-lab/ansible
ansible-playbook -i inventory/hosts.yml ../power/ansible/setup-idle-shutdown.yml
```

---

## 起動方法

Raspberry Pi から実行する。

```bash
bash ~/proxmox-lab/power/scripts/start-lab.sh
```

実行内容:
1. Wake-on-LAN で Proxmox を起動 (MAC アドレス設定済みの場合)
2. pve-node01 / pve-node02 / pve-node03 の SSH 接続可能まで待機
3. dns-ct → k3s-master → worker01〜07 の順に VM を起動
4. 全 k8s ノードが Ready になるまで待機
5. `kubectl uncordon` で全 worker を復帰

### Wake-on-LAN の設定

`power/scripts/start-lab.sh` 冒頭の `NODE01_MAC` / `NODE02_MAC` / `NODE03_MAC` に実際の MAC アドレスを記入する。
MAC アドレスの確認・WoL の事前設定手順は `scripts/README.md` の「7. Proxmox ノードの起動 (Wake-on-LAN)」を参照。

---

## 手動シャットダウン

アイドル検知を待たず即時シャットダウンする場合 (k8s drain は行わない):

```bash
cd ~/proxmox-lab/ansible
ansible-playbook -i inventory/hosts.yml ../power/ansible/shutdown.yml

# 確認プロンプトをスキップ
ansible-playbook -i inventory/hosts.yml ../power/ansible/shutdown.yml -e confirm=yes
```

---

## ログ・状態ファイル

| パス (pve-node01) | 内容 |
|-------------------|------|
| `/var/log/lab-idle-shutdown.log` | アイドルチェックと停止処理のログ |
| `/var/lib/lab-idle-shutdown/idle_count` | 現在の連続アイドルカウント |
| `/var/run/lab-idle-shutdown.lock` | 多重起動防止ロックファイル |

```bash
# カウントをリセットしてアイドル検知を最初からやり直す
ssh root@192.168.210.11 "echo 0 > /var/lib/lab-idle-shutdown/idle_count"
```
