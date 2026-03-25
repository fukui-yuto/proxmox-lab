# terraform/

Proxmox 上に VM / LXC コンテナをデプロイする Terraform 設定。

---

## 事前準備: シークレットファイルの作成

`terraform.tfvars` はパスワードを含むため Git 管理外。初回のみ手動で作成する。

```bash
cd ~/proxmox-lab/terraform
cp terraform.tfvars.example terraform.tfvars
nano terraform.tfvars
```

編集内容:

```hcl
proxmox_password = "Proxmox の root パスワード"
ssh_public_key   = "ssh-ed25519 AAAA..."  # cat ~/.ssh/id_ed25519.pub
ct_root_password = "LXC コンテナの root パスワード"
k3s_token        = ""  # k3s-master 起動後に取得 (後述)
```

---

## Debian LXC テンプレートの事前ダウンロード

DNS が不安定な場合は Raspberry Pi 経由で手動ダウンロードする。

```bash
# Raspberry Pi でダウンロード
wget -O /tmp/debian-12-standard_12.12-1_amd64.tar.zst \
  http://117.120.5.24/images/system/debian-12-standard_12.12-1_amd64.tar.zst \
  --header "Host: download.proxmox.com"

# node01 にコピー
scp /tmp/debian-12-standard_12.12-1_amd64.tar.zst \
  root@192.168.210.11:/var/lib/vz/template/cache/
```

---

## k3s トークンの取得 (worker03 参加に必要)

k3s-master/worker01/02 を先にデプロイ・k3s インストール後、以下でトークンを取得して `terraform.tfvars` に設定する。

```bash
ssh ubuntu@192.168.211.21 'sudo cat /var/lib/rancher/k3s/server/node-token'
```

取得した値を `terraform.tfvars` の `k3s_token` に設定してから worker03 を `terraform apply` でデプロイすると、VM 作成後に自動で k3s クラスターに参加する。

> **VM が既存の場合:** provisioner は初回作成時のみ実行される。
> `-replace` オプションで VM を再作成すること。
>
> ```bash
> cd ~/proxmox-lab/terraform
> terraform apply -replace=proxmox_virtual_environment_vm.k3s_worker_node02
> ```
>
> destroy が失敗する場合 (node02 が node01 の ZFS プールを参照できないエラー) は先に手動削除する:
>
> ```bash
> ssh root@192.168.210.12 'qm stop 204 --skiplock; qm destroy 204 --skiplock --purge'
> terraform apply -replace=proxmox_virtual_environment_vm.k3s_worker_node02
> ```

---

## VM / CT のデプロイ

```bash
cd ~/proxmox-lab/terraform

terraform init

terraform apply \
  -var "proxmox_password=<rootパスワード>" \
  -var "ssh_public_key=$(cat ~/.ssh/id_ed25519.pub)" \
  -var "ct_root_password=<コンテナパスワード>"
```

作成されるリソース:

| リソース | ノード | IP | ストレージ |
|---------|--------|-----|-----------|
| k3s-master | pve-node01 | 192.168.211.21 | data-pve-node01 (ZFS) |
| k3s-worker01 | pve-node01 | 192.168.211.22 | data-pve-node01 (ZFS) |
| k3s-worker02 | pve-node01 | 192.168.211.23 | data-pve-node01 (ZFS) |
| k3s-worker03 | pve-node02 | 192.168.211.24 | local-lvm |
| dns-ct (Pi-hole) | pve-node01 | 192.168.210.53 | data-pve-node01 (ZFS) |

---

## Proxmox Replication の設定 (VM 作成後・手動)

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
