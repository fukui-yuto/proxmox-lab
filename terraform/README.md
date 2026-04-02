# terraform/

Proxmox 上に VM / LXC コンテナをデプロイし、k3s クラスターを構成する。

作成されるリソース:

| リソース | ノード | IP | ストレージ | RAM |
|---------|--------|-----|-----------|-----|
| k3s-master | pve-node01 | 192.168.211.21 | data-pve-node01 (ZFS) | 2GB |
| k3s-worker01 | pve-node01 | 192.168.211.22 | data-pve-node01 (ZFS) | 4GB |
| k3s-worker02 | pve-node01 | 192.168.211.23 | data-pve-node01 (ZFS) | 4GB |
| k3s-worker03 | pve-node02 | 192.168.211.24 | local-lvm | 4GB |
| k3s-worker04 | pve-node02 | 192.168.211.25 | local-lvm | 4GB |
| dns-ct (Pi-hole) | pve-node01 | 192.168.210.53 | data-pve-node01 (ZFS) | 512MB |

worker03 / worker04 は pve-node02 に直接デプロイする。
クロスノードクローン + migration は node02 の ZFS がないため hang することがあるため、
`null_resource.node02_template` で node01 のテンプレート (9000) を vzdump → restore して
node02 にローカルテンプレート (9001) を作成し、同ノードクローンにすることで migration を回避する。

`terraform apply` 一発で以下が完結する:

1. VM / LXC コンテナ作成
2. ネットワークルート設定 (worker03/04 クロスノードルート・node01 側への逆ルート含む)
3. k3s master / worker01〜04 インストール・クラスター参加
4. kubeconfig を Raspberry Pi (`~/.kube/config`) に配置

---

## 構築手順 (初回)

### Step 1: 事前準備

`terraform.tfvars` はパスワードを含むため Git 管理外。初回のみ作成する。

```bash
cd ~/proxmox-lab/terraform
cp terraform.tfvars.example terraform.tfvars
nano terraform.tfvars
```

```hcl
proxmox_password = "Proxmox の root パスワード"
ssh_public_key   = "ssh-ed25519 AAAA..."  # cat ~/.ssh/id_ed25519.pub
ct_root_password = "LXC コンテナの root パスワード"
```

> **Debian LXC テンプレートが未取得の場合:**
>
> ```bash
> wget -O /tmp/debian-12-standard_12.12-1_amd64.tar.zst \
>   http://117.120.5.24/images/system/debian-12-standard_12.12-1_amd64.tar.zst \
>   --header "Host: download.proxmox.com"
>
> scp /tmp/debian-12-standard_12.12-1_amd64.tar.zst \
>   root@192.168.210.11:/var/lib/vz/template/cache/
> ```

### Step 2: デプロイ

```bash
cd ~/proxmox-lab/terraform
terraform init
terraform apply
```

完了後、クラスターの状態を確認する。

```bash
kubectl get nodes
```

出力例:
```
NAME           STATUS   ROLES                  AGE   VERSION
k3s-master     Ready    control-plane,master   5m    v1.34.x+k3s1
k3s-worker01   Ready    <none>                 3m    v1.34.x+k3s1
k3s-worker02   Ready    <none>                 2m    v1.34.x+k3s1
k3s-worker03   Ready    <none>                 1m    v1.34.x+k3s1
k3s-worker04   Ready    <none>                 1m    v1.34.x+k3s1
```

### Step 3: Proxmox Replication の設定 (手動)

VM をデプロイした後、Proxmox Web UI から Replication を設定する。
node01 ↔ node02 間で ZFS スナップショットが定期同期される。

1. `https://192.168.210.11:8006` にアクセス
2. 対象 VM を選択 → **Replication** タブ
3. **Add** をクリックして以下を設定する

| 項目 | 設定値 |
|------|--------|
| Target | もう一方のノード (pve-node02 等) |
| Schedule | `*/15` (15分ごと) |
| Rate limit | 空欄 (無制限) |

---

## 既存環境への変更適用

### node01 側 VM への逆方向ルート (既存 VM)

`main.tf` の `remote-exec` で設定しているルートは VM 新規作成時のみ自動適用される。
`null_resource.route_to_worker04` が worker04 追加時に自動で push するが、
手動で適用する場合は以下を使用する。

```bash
# worker03 (.24) へのルート
for ip in 192.168.211.21 192.168.211.22 192.168.211.23; do
  ssh ubuntu@${ip} "sudo tee /etc/netplan/99-worker03-route.yaml > /dev/null <<'EOF'
network:
  version: 2
  ethernets:
    eth0:
      routes:
        - to: 192.168.211.24/32
          via: 192.168.211.1
EOF
sudo chmod 600 /etc/netplan/99-worker03-route.yaml && sudo netplan apply"
done

# worker04 (.25) へのルート
for ip in 192.168.211.21 192.168.211.22 192.168.211.23; do
  ssh ubuntu@${ip} "sudo tee /etc/netplan/99-worker04-route.yaml > /dev/null <<'EOF'
network:
  version: 2
  ethernets:
    eth0:
      routes:
        - to: 192.168.211.25/32
          via: 192.168.211.1
EOF
sudo chmod 600 /etc/netplan/99-worker04-route.yaml && sudo netplan apply"
done
```
