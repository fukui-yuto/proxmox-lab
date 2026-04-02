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

## トラブルシューティング

### `null_resource.k3s_master_install` が失敗する

以下の2つが原因になりやすい:

1. **`cloud-init status --wait` が exit 1 を返す**
   Ubuntu cloud-init が degraded 状態で完了した場合でも exit 1 を返す既知の問題。
   `|| true` を付けて無視するよう対処済み (`main.tf:352`)。

2. **k3s ノード名が `k3s-master` にならない → `nodes "k3s-master" not found`**
   Proxmox は VM の `name` フィールドを cloud-init のホスト名に自動反映しない場合がある
   （テンプレートのホスト名が優先されることがある）。
   k3s はホスト名でノードを登録するため、インストール前に `hostnamectl set-hostname k3s-master`
   を実行する必要がある。`main.tf:372` で対処済み。
   `proxmox_virtual_environment_vm` の `initialization` ブロックは `hostname` 属性に未対応
   （`hostname` は LXC コンテナ専用）。

### `null_resource.k3s_worker03_install` が 10 分タイムアウトで失敗する

worker03 (192.168.210.24) の k3s バイナリダウンロードが IPv6 経由でハングする。
他のワーカーは既にインストール済みのためキャッシュ利用で速いが、worker03 は初回で発生する。
`/etc/gai.conf` の IPv4 優先設定をアンコメントしてからインストールするよう対処済み (`main.tf:421`)。

### kubeconfig の証明書エラー (`x509: certificate signed by unknown authority`)

k3s を再インストールすると証明書が再生成される。`~/.kube/config` を手動で更新する:
```bash
ssh -o StrictHostKeyChecking=no ubuntu@192.168.210.21 'sudo cat /etc/rancher/k3s/k3s.yaml' > ~/.kube/config
sed -i 's/127.0.0.1/192.168.210.21/g' ~/.kube/config
```
`kubeconfig_setup` は `scp` ではなく `ssh sudo cat` で取得するよう修正済み (`main.tf:485`)。
ubuntu ユーザーは `/etc/rancher/k3s/k3s.yaml` を直接読めないため。

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
