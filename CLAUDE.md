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
| k3s-worker08 | 209 | 192.168.210.29 | pve-node03 | k3s ワーカー |
| k3s-worker09 | 210 | 192.168.210.30 | pve-node03 | k3s ワーカー |
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
  - VM / LXC のプロビジョニング・設定 → **Terraform** (OS 内操作も含む)
  - k8s アプリの設定 → **Helm values** または **マニフェスト**
- `ip addr add` や `sysctl` の直接実行などを提案しない。必ず Ansible playbook / Terraform remote-exec で実装する
- k3s ノードの設定は `terraform/main.tf` の `remote-exec` で管理する。Ansible には書かない

### Ansible のスコープ (重要)

Ansible の対象は **Proxmox ホスト OS (pve-node01/02/03) と Raspberry Pi のみ**。

- `ansible/inventory/hosts.yml` に k3s ワーカー VM を追加しない
- k3s ワーカー VM 内での操作 (パッケージインストール・ディスク拡張・設定変更) は Terraform の `remote-exec` / `local-exec` で実装する
- 間違いやすい例: ディスク拡張のために VM に Ansible playbook を書く → **NG**。Terraform `null_resource` + `remote-exec` で実装する

### Terraform のスコープと実装パターン

**実行環境:** Terraform は Raspberry Pi (192.168.210.55) 上の `~/proxmox-lab/terraform` で実行される。

- **git push 必須**: Windows でのファイル編集は `git commit && git push` → Raspberry Pi で `git pull` しないと `terraform plan/apply` に反映されない。編集後に plan が期待通りでない場合はまず git の同期を確認する
- **`local-exec` の実行場所**: Raspberry Pi 上で実行される。`ssh root@192.168.210.13 'qm resize ...'` のように Proxmox ホストへの SSH が可能
- **`remote-exec` はリソース作成時のみ実行**: 既存リソースに再実行させるには `null_resource` + `triggers` パターンを使う

**既存 VM への変更パターン (例: ディスク拡張):**
```hcl
# 1. local 変数でサイズを管理 (triggers のトリガー値として使う)
locals {
  worker_node03_disk_size = 50
}

# 2. VM リソースのディスクに local 参照
disk {
  size = local.worker_node03_disk_size
}

# 3. null_resource でサイズ変更時に自動実行
resource "null_resource" "expand_disk_node03" {
  count = 4
  triggers = {
    disk_size = local.worker_node03_disk_size  # 値が変わると再実行
  }
  depends_on = [proxmox_virtual_environment_vm.k3s_worker_node03]

  provisioner "local-exec" {
    command = "ssh root@192.168.210.13 'qm resize ${207 + count.index} virtio0 ${local.worker_node03_disk_size}G'"
  }
  connection { ... }
  provisioner "remote-exec" {
    inline = ["sudo growpart /dev/vda 2 || true", "sudo resize2fs /dev/vda2"]
  }
}
```

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
| **常時起動** (automated sync) | longhorn | 分散永続ストレージ (他アプリの PVC の前提) |
| **常時起動** (automated sync) | vault | シークレット管理 |
| **常時起動** (automated sync) | monitoring (kube-prometheus-stack) | クラスター監視 |
| **常時起動** (automated sync) | harbor | コンテナイメージレジストリ |
| **常時起動** (automated sync) | keycloak | SSO / 認証基盤 |
| **常時起動** (automated sync) | logging (elasticsearch / fluent-bit / kibana) | ログ収集・閲覧 |
| **常時起動** (automated sync) | tracing (tempo / otel-collector) | 分散トレーシング |
| **常時起動** (automated sync) | argo-workflows / argo-events | 自動修復ワークフロー |
| **常時起動** (automated sync) | aiops (alerting / anomaly-detection / alert-summarizer / auto-remediation) | 予測アラート・ログ異常検知・自動修復 |
| **常時起動** (automated sync) | minio | S3 互換オブジェクトストレージ (Velero バックアップ先) |
| **常時起動** (automated sync) | cert-manager / cert-manager-issuers | TLS 証明書の自動発行・更新 (homelab 内部 CA) |
| **常時起動** (automated sync) | velero | k8s リソース・PVC の定期バックアップ・DR |
| **常時起動** (automated sync) | argo-rollouts | カナリア / Blue-Green プログレッシブデリバリー |
| **常時起動** (automated sync) | keda | イベント駆動オートスケーリング (Prometheus / Kafka 等) |
| **常時起動** (automated sync) | falco | syscall レベルのランタイム脅威検知 |
| **常時起動** (automated sync) | trivy-operator | コンテナイメージ・設定の継続的脆弱性スキャン |
| **常時起動** (automated sync) | litmus | カオスエンジニアリング (aiops-auto-remediation の動作検証) |
| **常時起動** (automated sync) | backstage | 開発者ポータル / サービスカタログ |
| **常時起動** (automated sync) | crossplane | k8s CRD によるインフラ宣言的管理 (Terraform 代替候補) |
| **常時起動** (automated sync) | cilium | eBPF CNI + Hubble ネットワーク可観測性 (flannel 移行完了・全ノード稼働中) |

### ArgoCD Sync Wave (起動順序)

全アプリ一斉起動による pve-node01 NIC ハング対策として段階的に起動する。

| Wave | アプリ |
|------|--------|
| 0 | kyverno |
| 1 | kyverno-policies |
| 2 | longhorn-prereqs / longhorn |
| 3 | vault / minio / cert-manager |
| 4 | monitoring / argo-workflows / argo-events / cert-manager-issuers / velero / argo-rollouts / keda / falco |
| 5 | harbor / trivy-operator |
| 16 | litmus / backstage / crossplane |
| 0 | cilium (Wave 0、flannel 置き換え完了) |
| 6 | keycloak |
| 7 | logging-elasticsearch |
| 8 | logging-fluent-bit |
| 9 | logging-kibana |
| 10 | tracing-tempo |
| 11 | tracing-otel-collector |
| 12 | aiops-alerting / aiops-pushgateway / aiops-image-build |
| 13 | aiops-alert-summarizer / aiops-anomaly-detection |
| 14 | aiops-auto-remediation |
| 15 | aiops-auto-remediation-events |

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

### Cilium kubeProxyReplacement と ClusterIP 全断

**症状:** `kubeProxyReplacement: true` に設定すると DNS を含む全 ClusterIP が到達不能になり、ArgoCD・全サービス間通信が全断する

**原因:** KPR=true + tunnel (VXLAN) モードでは socketLB (cgroup BPF) が ClusterIP DNAT を処理する必要があるが、k3s の containerd 環境では Cilium コンテナの cgroup namespace がホストと分離されており BPF プログラムが Pod の cgroup にアタッチ不能

**対処:**
- `k8s/cilium/values.yaml` で `kubeProxyReplacement: false` を維持 (**絶対に true にしない**)
- `bpf.masquerade: false` (KPR=false では NodePort BPF が無効のため)
- 詳細は `k8s/cilium/README.md` の「kube-proxy-replacement 設定」セクション参照

### Cilium ローリングリスタート後の Longhorn ボリューム障害

**症状:** Cilium DaemonSet の再起動後に Longhorn ボリュームが faulted/detaching でスタックし、Pod が I/O エラーでクラッシュする

**原因:** Cilium 再起動で Pod ネットワークが更新されるが、既存の Longhorn instance-manager Pod が古いネットワーク情報のまま残り、manager 間の gRPC 通信が不能になる

**対処:**
1. Cilium ローリングリスタート完了を待つ
2. Longhorn instance-manager Pod を全削除: `kubectl delete pods -n longhorn-system -l longhorn.io/component=instance-manager`
3. ボリュームの状態を確認: `kubectl get volumes.longhorn.io -n longhorn-system`

---

## k8s アクセス情報

### Windows hosts ファイルへの追記

> pve-node02 の worker IP を使うことで node01 の NIC 負荷を分散できる。
> **192.168.210.25 (worker04)** を使用する。192.168.210.24 (worker03) は Traefik Pod が稼働するため
> Cilium ExternalIP のローカルバックエンド問題により外部からの接続が不安定になる場合がある。

```powershell
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.25  grafana.homelab.local"
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.25  kibana.homelab.local"
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.25  elasticsearch.homelab.local"
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.25  argocd.homelab.local"
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.25  longhorn.homelab.local"
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.25  harbor.homelab.local"
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.25  keycloak.homelab.local"
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.25  vault.homelab.local"
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.25  argo-workflows.homelab.local"
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.25  alert-summarizer.homelab.local"
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.25  minio.homelab.local"
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.25  minio-api.homelab.local"
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
| Argo Workflows | http://argo-workflows.homelab.local | - | 認証不要 |
| alert-summarizer | http://alert-summarizer.homelab.local | - | - |
| MinIO Console | http://minio.homelab.local | `admin` | `Minio12345` |
