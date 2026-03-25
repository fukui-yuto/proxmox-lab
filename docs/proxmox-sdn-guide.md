# Proxmox SDN 設定ガイド

Proxmox VE の SDN (Software Defined Networking) を使って VXLAN ベースの仮想ネットワークを構築する手順。

## 概要

### SDN の構成

```
Proxmox Cluster
├── SDN Zone: vxlan-lab (VXLAN)
│   └── VNet: vnet-lab (VNID: 1000)
└── 各ノードに VXLAN トンネルを自動設定
```

### VXLAN の役割

VXLAN (Virtual eXtensible LAN) を使うと、物理的に異なるノード上の VM/コンテナが同一 L2 セグメント上にいるように通信できる。

| 項目 | 値 |
|------|-----|
| Zone 名 | `vxlan-lab` |
| Zone タイプ | VXLAN |
| VNet 名 | `vnet-lab` |
| VNID | 1000 |
| Peers | 192.168.210.11, 192.168.210.12 |

## Proxmox WebUI での設定手順

### STEP 1: SDN 機能の有効化確認

1. Proxmox WebUI にアクセス: `https://192.168.210.11:8006`
2. 左ペインの "Datacenter" をクリック
3. "SDN" メニューが表示されていることを確認

> SDN メニューが表示されない場合は `libpve-network-perl` パッケージをインストールする。
>
> ```bash
> apt install libpve-network-perl
> systemctl restart pvedaemon
> ```

### STEP 2: VXLAN ゾーンの作成

1. Datacenter → SDN → Zones タブ
2. "Add" ボタンをクリック
3. 以下を入力:
   - Type: **VXLAN**
   - Zone ID: **vxlan-lab**
   - Peers Address: **192.168.210.11,192.168.210.12**
4. "Create" をクリック

### STEP 3: VNet の作成

1. Datacenter → SDN → VNets タブ
2. "Add" ボタンをクリック
3. 以下を入力:
   - Name: **vnet-lab**
   - Zone: **vxlan-lab**
   - Tag (VNID): **1000**
4. "Create" をクリック

### STEP 4: SDN 設定の適用

1. Datacenter → SDN → Overview タブ
2. "Apply" ボタンをクリック
3. 全ノードに設定が配布されるまで待機 (数十秒)

> "Apply" を忘れると SDN 設定が各ノードに反映されない。

### STEP 5: VM への VNet 割り当て

1. VM の設定画面を開く
2. "Hardware" タブ → "Add" → "Network Device"
3. Bridge: **vnet-lab** を選択
4. "Add" をクリック
5. VM を再起動して設定を反映

## コマンドラインでの設定手順

Proxmox ノードで `pvesh` コマンドを使って設定する。

### VXLAN ゾーンの作成

```bash
pvesh create /cluster/sdn/zones \
  --zone vxlan-lab \
  --type vxlan \
  --peers "192.168.210.11,192.168.210.12"
```

### VNet の作成

```bash
pvesh create /cluster/sdn/vnets \
  --vnet vnet-lab \
  --zone vxlan-lab \
  --tag 1000
```

### SDN 設定の適用

```bash
pvesh set /cluster/sdn
```

### Ansible Playbook での設定

```bash
cd ~/proxmox-lab

# SDN 設定のみ実行
ansible-playbook ansible/playbooks/05-proxmox-sdn.yml --tags sdn

# 確認のみ
ansible-playbook ansible/playbooks/05-proxmox-sdn.yml --tags check
```

## 設定後の確認コマンド

### SDN ゾーンの確認

```bash
# Proxmox ノードで実行
pvesh get /cluster/sdn/zones --output-format json | python3 -m json.tool

# または
pvesh get /cluster/sdn/zones/vxlan-lab
```

### VNet の確認

```bash
pvesh get /cluster/sdn/vnets --output-format json | python3 -m json.tool
pvesh get /cluster/sdn/vnets/vnet-lab
```

### ネットワークインターフェースの確認

```bash
# 各ノードで VXLAN インターフェースが作成されているか確認
ip link show | grep vxlan
ip link show vnet-lab

# VXLAN のトンネル状態確認
bridge fdb show dev vxlan_vnet-lab
```

### VM 間の疎通確認

```bash
# vnet-lab に接続した 2 つの VM 間で ping
ping <対向 VM の IP>

# VXLAN のカプセル化を確認 (tcpdump)
tcpdump -i vmbr0 -n 'udp port 4789'  # VXLAN は UDP 4789 番を使用
```

## トラブルシューティング

### SDN Apply に失敗する場合

```bash
# Proxmox ノードのログを確認
journalctl -u pve-sdn -f

# pve-sdn サービスを再起動
systemctl restart pve-sdn
```

### VXLAN トンネルが確立しない場合

```bash
# ファイアウォールで UDP 4789 が許可されているか確認
iptables -L -n | grep 4789

# Proxmox ノード間の疎通確認
ping 192.168.210.12  # pve-node01 から pve-node02 へ
```

### VNet が VM に表示されない場合

1. SDN の "Apply" が実行されているか確認
2. VM が配置されているノードで VNet が認識されているか確認:
   ```bash
   ip link show vnet-lab
   ```

## 参考

- [Proxmox VE SDN 公式ドキュメント](https://pve.proxmox.com/wiki/SDN)
- [VXLAN の仕様 (RFC 7348)](https://datatracker.ietf.org/doc/html/rfc7348)
