# terraform/

Proxmox 上に VM / LXC コンテナをデプロイし、k3s クラスターを構成する。

作成されるリソース:

| リソース | ノード | IP | ストレージ | RAM |
|---------|--------|-----|-----------|-----|
| k3s-master | pve-node01 | 192.168.210.21 | data-pve-node01 (ZFS) | 4GB |
| k3s-worker01 | pve-node01 | 192.168.210.22 | data-pve-node01 (ZFS) | 4GB |
| k3s-worker02 | pve-node01 | 192.168.210.23 | data-pve-node01 (ZFS) | 4GB |
| k3s-worker03 | pve-node02 | 192.168.210.24 | local-lvm | 4GB |
| k3s-worker04 | pve-node02 | 192.168.210.25 | local-lvm | 4GB |
| k3s-worker05 | pve-node02 | 192.168.210.26 | local-lvm | 4GB |
| dns-ct (Pi-hole) | pve-node01 | 192.168.210.53 | data-pve-node01 (ZFS) | 512MB |

VM はすべて Ubuntu 24.04 テンプレート (`ubuntu_template_id`) から clone して作成する。
`dns-ct` は Debian 12 LXC コンテナで、**Pi-hole** を動かすネットワーク全体の DNS サーバー。
広告・トラッキングドメインをブロックし、クラスター内の名前解決も担う。
IP が `192.168.210.53` なのは DNS ポート (53) に合わせた命名。

全 VM は管理ネットワーク (192.168.210.0/24) に直接接続し、ゲートウェイは 192.168.210.254。
クロスノードルーティングは不要 (同一 L2 セグメント)。

worker03 / worker04 は pve-node02 に直接デプロイする。
クロスノードクローン + migration は node02 の ZFS がないため hang することがあるため、
`null_resource.node02_template` で node01 のテンプレート (9000) を vzdump → restore して
node02 にローカルテンプレート (9001) を作成し、同ノードクローンにすることで migration を回避する。

`terraform apply` 一発で以下が完結する:

1. VM / LXC コンテナ作成
2. k3s master / worker01〜04 インストール・クラスター参加
3. kubeconfig を Raspberry Pi (`~/.kube/config`) に配置

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
k3s-worker05   Ready    <none>                 1m    v1.34.x+k3s1
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
