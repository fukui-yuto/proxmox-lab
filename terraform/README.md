# terraform/

Proxmox 上に VM / LXC コンテナをデプロイし、k3s クラスターを構成する。

作成されるリソース:

| リソース | ノード | IP | ストレージ | RAM |
|---------|--------|-----|-----------|-----|
| k3s-master | pve-node01 | 192.168.210.21 | data-pve-node01 (ZFS) | 4GB |
| k3s-worker01 | pve-node01 | 192.168.210.22 | data-pve-node01 (ZFS) | 4GB |
| k3s-worker03 | pve-node02 | 192.168.210.24 | local-lvm | 4GB |
| k3s-worker04 | pve-node02 | 192.168.210.25 | local-lvm | 4GB |
| k3s-worker05 | pve-node02 | 192.168.210.26 | local-lvm | 4GB |
| k3s-worker06 | pve-node03 | 192.168.210.27 | local (qcow2) | 4GB |
| k3s-worker07 | pve-node03 | 192.168.210.28 | local (qcow2) | 4GB |
| k3s-worker08 | pve-node03 | 192.168.210.29 | local (qcow2) | 4GB |
| k3s-worker09 | pve-node03 | 192.168.210.30 | local (qcow2) | 4GB |
| dns-ct (Pi-hole) | pve-node01 | 192.168.210.53 | data-pve-node01 (ZFS) | 512MB |

VM はすべて Ubuntu 24.04 テンプレート (`ubuntu_template_id`) から clone して作成する。
`dns-ct` は Debian 12 LXC コンテナで、**Pi-hole** を動かすネットワーク全体の DNS サーバー。
広告・トラッキングドメインをブロックし、クラスター内の名前解決も担う。
IP が `192.168.210.53` なのは DNS ポート (53) に合わせた命名。

全 VM は管理ネットワーク (192.168.210.0/24) に直接接続し、ゲートウェイは 192.168.210.254。
クロスノードルーティングは不要 (同一 L2 セグメント)。

worker03〜05 は pve-node02、worker06〜09 は pve-node03 に直接デプロイする。
クロスノードクローン + migration は ZFS がないノードで hang することがあるため、
`null_resource.node02_template` / `null_resource.node03_template` で node01 のテンプレート (9000) を vzdump → restore して
各ノードにローカルテンプレート (9001/9002) を作成し、同ノードクローンにすることで migration を回避する。

`terraform apply` 一発で以下が完結する:

1. VM / LXC コンテナ作成
2. k3s master / worker01,03〜09 インストール・クラスター参加
3. kubeconfig を Raspberry Pi (`~/.kube/config`) に配置
4. k3s レジストリ設定 (`/etc/rancher/k3s/registries.yaml`) を全ノードに配布

---

## コード構造

### `locals` ブロック

ネットワーク設定・SSH 鍵パス・ワーカー IP リストを一元管理している。
値を変更する場合は `main.tf` の `locals` ブロックのみ編集すれば全リソースに反映される。

```hcl
locals {
  gateway     = "192.168.210.254"
  dns_servers = ["192.168.210.254", "8.8.8.8"]
  master_ip   = "192.168.210.21"
  ssh_key     = "~/.ssh/id_ed25519"
  worker_ips  = ["192.168.210.22", ..., "192.168.210.26"]
}
```

### worker インストールリソース

`null_resource.k3s_workers_install` (count=8) で worker01,03〜09 を統一管理。
worker02 は削除済み。worker_ips[1] (192.168.210.23) はスキップするため index にオフセットを加算している。
- index 0 → `k3s_worker[0]` (node01, worker_ips[0])
- index 1/2/3 → `k3s_worker_node02[0/1/2]` (node02, worker_ips[2/3/4])
- index 4/5/6/7 → `k3s_worker_node03[0/1/2/3]` (node03, worker_ips[5/6/7/8])

### `StrictHostKeyChecking=no` について

destroy → apply のたびに VM のホストキーが変わるため、ラボ内ネットワーク (192.168.210.0/24) 向けの接続に限り `StrictHostKeyChecking=no` を使用している。
インターネット越しのホストには使用しないこと。

---

## トラブルシューティング

### `null_resource.k3s_master_install` が失敗する

以下の2つが原因になりやすい:

1. **`cloud-init status --wait` が exit 1 を返す**
   Ubuntu cloud-init が degraded 状態で完了した場合でも exit 1 を返す既知の問題。
   `|| true` を付けて無視するよう対処済み。

2. **k3s ノード名が `k3s-master` にならない → `nodes "k3s-master" not found`**
   Proxmox は VM の `name` フィールドを cloud-init のホスト名に自動反映しない場合がある
   （テンプレートのホスト名が優先されることがある）。
   k3s はホスト名でノードを登録するため、インストール前に `hostnamectl set-hostname k3s-master`
   を実行する必要がある。対処済み。
   `proxmox_virtual_environment_vm` の `initialization` ブロックは `hostname` 属性に未対応
   （`hostname` は LXC コンテナ専用）。

### worker の k3s インストールが 10 分タイムアウトで失敗する

k3s バイナリダウンロードが IPv6 経由でハングする場合がある。
`/etc/curlrc` に `ipv4` を書くことで全 curl 呼び出し（k3s インストールスクリプト内部含む）を
IPv4 に強制するよう対処済み。`gai.conf` の sed パターンマッチは不安定なため採用しない。

### node03 (BOSGAME E2) で `no such logical volume pve/data` が出る

BOSGAME E2 は Proxmox インストール時に LVM thin pool (`pve/data`) が作成されないため `local-lvm` が inactive になる。
`local` (dir) ストレージを使用するよう対処済み。

追加で以下の設定が必要：
- `local` ストレージの content に `images,rootdir` を追加（`pvesm set local --content iso,vztmpl,backup,images,rootdir`）→ `node03_template` の前処理に組み込み済み
- `initialization` ブロックに `datastore_id = "local"` を明示指定（cloud-init ドライブが `local-lvm` に作成されるのを防ぐ）→ 対処済み

### kubeconfig の証明書エラー (`x509: certificate signed by unknown authority`)

k3s を再インストールすると証明書が再生成される。`terraform apply` で `kubeconfig_setup` が
自動的に再実行され `~/.kube/config` を更新する（`k3s_master_install.id` をトリガーに使用）。

手動で更新する場合:
```bash
ssh -o StrictHostKeyChecking=no ubuntu@192.168.210.21 'sudo cat /etc/rancher/k3s/k3s.yaml' > ~/.kube/config
sed -i 's/127.0.0.1/192.168.210.21/g' ~/.kube/config
```
`kubeconfig_setup` は `scp` ではなく `ssh sudo cat` で取得する。
ubuntu ユーザーは `/etc/rancher/k3s/k3s.yaml` を直接読めないため。

---

## ワーカーノードの増減

### worker08/09 の追加 (実施済み: 2026-04-11)

pve-node03 (Ryzen 5 3550H / 32GB) の余剰リソース (RAM 17GB 空き / 2コア空き) を活用して追加。

`main.tf` の変更内容:
- `worker_ips` に 192.168.210.29 / 192.168.210.30 を追加
- `k3s_worker_node03` count: 2 → 4
- `k3s_workers_install` count: 6 → 8 (index マッピングも調整)
- `k3s_registry_config` の IP リストに 192.168.210.29 / 192.168.210.30 を追加

pve-node03 は `local` (dir) ストレージを使用するため `file_format = "qcow2"` を指定する。

---

### worker02 の削除 (実施済み)

`main.tf` の変更内容:
- `k3s_worker` count: 2 → 1
- `k3s_workers_install` count: 7 → 6 (index マッピングも調整)

ラボが起動している状態で以下の手順を実行する。

**Step 1: k3s からノードを drain して削除**

```bash
# ワークロードを退避
kubectl drain k3s-worker02 --ignore-daemonsets --delete-emptydir-data
# クラスターから削除
kubectl delete node k3s-worker02
```

**Step 2: Terraform で VM を削除**

```bash
cd ~/proxmox-lab/terraform
terraform apply
```

`proxmox_virtual_environment_vm.k3s_worker[1]` と `null_resource.k3s_workers_install[6]` が destroy される。

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
k3s-worker03   Ready    <none>                 1m    v1.34.x+k3s1
k3s-worker04   Ready    <none>                 1m    v1.34.x+k3s1
k3s-worker05   Ready    <none>                 1m    v1.34.x+k3s1
k3s-worker06   Ready    <none>                 1m    v1.34.x+k3s1
k3s-worker07   Ready    <none>                 1m    v1.34.x+k3s1
k3s-worker08   Ready    <none>                 1m    v1.34.x+k3s1
k3s-worker09   Ready    <none>                 1m    v1.34.x+k3s1
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
