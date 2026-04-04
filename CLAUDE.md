# CLAUDE.md

このリポジトリは Proxmox ホームラボの IaC (Infrastructure as Code) 管理リポジトリ。

---

## インフラ構成

### ハードウェア

| ホスト名 | IP | スペック | 役割 |
|---------|-----|---------|------|
| pve-node01 | 192.168.210.11 | NUC5i3RYH / i3-5010U / 16GB | Proxmox ノード (ZFS あり) |
| pve-node02 | 192.168.210.12 | NUC5i3RYH / i3-5010U / 16GB | Proxmox ノード |
| pve-node03 | 192.168.210.13 | BOSGAME E2 / Ryzen 5 3550H / 32GB | Proxmox ノード |
| Raspberry Pi 5 | 192.168.210.55 | - | 管理端末 / corosync-qnetd / Ansible・Terraform 実行環境 |

### VM / コンテナ構成 (Terraform 管理)

| 名前 | VM ID | IP | Proxmox ノード | 役割 |
|------|-------|----|--------------|------|
| k3s-master | 201 | 192.168.210.21 | pve-node01 | k3s コントロールプレーン |
| k3s-worker01 | 202 | 192.168.210.22 | pve-node01 | k3s ワーカー |
| k3s-worker03 | 204 | 192.168.210.24 | pve-node02 | k3s ワーカー |
| k3s-worker04 | 205 | 192.168.210.25 | pve-node02 | k3s ワーカー |
| k3s-worker05 | 206 | 192.168.210.26 | pve-node02 | k3s ワーカー |
| k3s-worker06 | 207 | 192.168.210.27 | pve-node03 | k3s ワーカー |
| k3s-worker07 | 208 | 192.168.210.28 | pve-node03 | k3s ワーカー |
| dns-ct | 101 | 192.168.210.53 | pve-node01 | Pi-hole DNS (LXC) |

> worker02 (VM 203) は削除済み。

### ネットワーク

| VLAN | 用途 | サブネット |
|------|------|-----------|
| 1 (native) | 管理 / VM / 既存 LAN | 192.168.210.0/24 |
| 20 | ストレージ / Proxmox レプリケーション | 192.168.212.0/24 |

---

## ディレクトリ構成

| ディレクトリ | 用途 |
|---|---|
| `terraform/` | Proxmox VM / LXC のプロビジョニング |
| `ansible/` | Proxmox ホスト OS の設定管理 |
| `k8s/` | k3s クラスター上のアプリデプロイ |
| `packer/` | VM テンプレートのビルド |
| `scripts/` | 補助スクリプト |
| `power/` | クラスターの起動・シャットダウン管理 |

---

## 作業ルール

### 設定変更

- **手動コマンドは確認のみ許容**。設定変更は必ず以下のツールで実装する:
  - Proxmox ホスト OS の設定 → **Ansible**
  - VM / LXC のプロビジョニング → **Terraform**
  - k8s アプリの設定 → **Helm values** または **マニフェスト**
- `ip addr add` や `sysctl` の直接実行などを提案しない。必ず Ansible playbook / Terraform remote-exec で実装する
- k3s ノードの設定は `terraform/main.tf` の `remote-exec` で管理する。Ansible には書かない

### ドキュメント

- コマンドや手順は **変更対象のディレクトリにある README.md に必ず記載する**
  - `terraform/` の変更 → `terraform/README.md`
  - `ansible/` の変更 → `ansible/README.md`
  - `k8s/monitoring/` の変更 → `k8s/monitoring/README.md`
  - （以下同様）
- 口頭での説明だけで済ませない。README.md への記載 + git push まで行う
- 各 k8s ディレクトリの `GUIDE.md` はツールの概念説明・学習用ドキュメント。手順は README.md に書く

### Git

- ファイル修正・作成のたびに `git commit && git push` まで実施する

### ラボへのアクセス

- Windows 端末から直接 SSH でラボ (Raspberry Pi / Proxmox ノード / VM) に接続しない
- ラボへの操作・確認は必ず **MCP ツール (`mcp__proxmox-lab__` 系)** 経由で行う

| MCPツール | 用途 |
|----------|------|
| `ansible_run_playbook` | Ansible playbook の実行 |
| `ansible_ping` | 疎通確認 |
| `lab_ping` | IP への ping |
| `kubectl_get`, `kubectl_logs` | k8s 操作・確認 |
| `proxmox_get_vm_status`, `proxmox_list_nodes` | Proxmox 状態確認 |
| `terraform_plan`, `terraform_apply` | Terraform 操作 |

---

## k8s アプリ管理

### 常時起動 / オンデマンド

| 種別 | アプリ | 理由 |
|------|--------|------|
| **常時起動** (automated sync) | kyverno, kyverno-policies | Webhook が落ちるとクラスター操作不能になるため必須 |
| **常時起動** (automated sync) | monitoring (kube-prometheus-stack) | クラスター監視 |
| **常時起動** (automated sync) | logging (elasticsearch / fluent-bit / kibana) | ログ収集・閲覧 |
| **オンデマンド** (手動 sync) | vault | シークレット管理が必要な時 |
| **オンデマンド** (手動 sync) | harbor | イメージビルド・push 時 |
| **オンデマンド** (手動 sync) | keycloak | SSO が必要な時 |
| **オンデマンド** (手動 sync) | tracing (tempo / otel-collector) | トレース調査時 |

### ArgoCD Sync Wave (起動順序)

全アプリ一斉起動による pve-node01 NIC ハング対策として段階的に起動する。

| Wave | アプリ |
|------|--------|
| 0 | kyverno |
| 1 | kyverno-policies |
| 2 | vault |
| 3 | monitoring |
| 4 | harbor |
| 5 | keycloak |
| 6 | logging-elasticsearch |
| 7 | logging-fluent-bit |
| 8 | logging-kibana |
| 9 | tracing-tempo |
| 10 | tracing-otel-collector |

---

## 既知の問題と対処

### pve-node01 e1000e NIC Hardware Unit Hang

**症状:** k8s の全アプリを一斉起動すると pve-node01 の NIC がハングし、Corosync クォーラム喪失 → クラッシュ

**対処:**
1. k8s 起動前に必ず NIC チューニングを適用する:
   ```bash
   ansible-playbook -i inventory/hosts.yml playbooks/08-nic-tuning.yml
   ```
2. ArgoCD Sync Wave で起動を段階的に分散する (上記参照)

**適用済みチューニング (`ansible/playbooks/08-nic-tuning.yml`):**

| 設定 | 値 | 効果 |
|------|-----|------|
| TSO/GSO/GRO 無効化 | off | NIC ファームウェア負荷軽減 |
| RX/TX リングバッファ | 4096 | バースト時のパケットドロップ防止 |
| 割り込みコアレシング | rx-usecs/tx-usecs=50 | 割り込みストーム抑制 |
| txqueuelen | 10000 | 送信キュー詰まり防止 |

---

## k8s アクセス情報

### Windows hosts ファイルへの追記

> pve-node02 の worker IP (192.168.210.24) を使うことで node01 の NIC 負荷を分散できる。

```powershell
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.24  grafana.homelab.local"
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.24  kibana.homelab.local"
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.24  elasticsearch.homelab.local"
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.24  argocd.homelab.local"
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.24  harbor.homelab.local"
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.24  keycloak.homelab.local"
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.24  vault.homelab.local"
```

### URL 一覧

| アプリ | URL | ユーザー | 初期パスワード |
|--------|-----|---------|--------------|
| Grafana | http://grafana.homelab.local | `admin` | `values.yaml` の `grafana.adminPassword` |
| Kibana | http://kibana.homelab.local | - | - |
| Elasticsearch | http://elasticsearch.homelab.local | - | - |
| ArgoCD | http://argocd.homelab.local | `admin` | `Argocd12345` |
| Harbor | http://harbor.homelab.local | `admin` | `Harbor12345` |
| Keycloak | http://keycloak.homelab.local | `admin` | `Keycloak12345` |
| Vault | http://vault.homelab.local | - | 初期化時の Root Token (要 unseal) |
