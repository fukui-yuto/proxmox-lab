# terraform/

Proxmox 上に VM / LXC コンテナをデプロイする Terraform 設定。

作成されるリソース:

| リソース | ノード | IP | ストレージ |
|---------|--------|-----|-----------|
| k3s-master | pve-node01 | 192.168.211.21 | data-pve-node01 (ZFS) |
| k3s-worker01 | pve-node01 | 192.168.211.22 | data-pve-node01 (ZFS) |
| k3s-worker02 | pve-node01 | 192.168.211.23 | data-pve-node01 (ZFS) |
| k3s-worker03 | pve-node02 | 192.168.211.24 | local-lvm |
| dns-ct (Pi-hole) | pve-node01 | 192.168.210.53 | data-pve-node01 (ZFS) |

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
k3s_token        = ""  # この時点では空のままでよい
```

> **Debian LXC テンプレートが未取得の場合:**
>
> ```bash
> # Raspberry Pi でダウンロード
> wget -O /tmp/debian-12-standard_12.12-1_amd64.tar.zst \
>   http://117.120.5.24/images/system/debian-12-standard_12.12-1_amd64.tar.zst \
>   --header "Host: download.proxmox.com"
>
> # node01 にコピー
> scp /tmp/debian-12-standard_12.12-1_amd64.tar.zst \
>   root@192.168.210.11:/var/lib/vz/template/cache/
> ```

### Step 2: VM 作成 (k3s_token は空のまま)

```bash
cd ~/proxmox-lab/terraform
terraform init
terraform apply
```

この時点で以下が自動設定される:
- master / worker01 / worker02: worker03 への逆方向ルート (`192.168.211.24/32 via 192.168.211.1`)
- worker03: master / worker01 / worker02 へのクロスノードルート

k3s のインストールは Terraform 管理外のため、次の Step で行う。

### Step 3: k3s インストール

→ [k8s/README.md](../k8s/README.md) の手順に従い master / worker01 / worker02 に k3s をインストールする。

### Step 4: worker03 を k3s クラスターに参加させる

k3s-master からトークンを取得して `terraform.tfvars` に設定する。

```bash
ssh ubuntu@192.168.211.21 'sudo cat /var/lib/rancher/k3s/server/node-token'
```

取得した値を `terraform.tfvars` の `k3s_token` に設定してから worker03 を再作成する。

```bash
cd ~/proxmox-lab/terraform
terraform apply -replace=proxmox_virtual_environment_vm.k3s_worker_node02
```

> **destroy が失敗する場合** (node02 が node01 の ZFS プールを参照できないエラー):
>
> ```bash
> ssh root@192.168.210.12 'qm stop 204 --skiplock; qm destroy 204 --skiplock --purge'
> terraform apply -replace=proxmox_virtual_environment_vm.k3s_worker_node02
> ```

### Step 5: Proxmox Replication の設定 (手動)

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

### master/worker01/02 への worker03 逆方向ルート (既存 VM)

`main.tf` の `remote-exec` で設定しているルートは VM 新規作成時のみ自動適用される。
既存 VM に適用するには以下の SSH コマンドを使用する。

```bash
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
```
