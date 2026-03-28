# CLAUDE.md

このリポジトリは Proxmox ホームラボの IaC (Infrastructure as Code) 管理リポジトリ。

## ディレクトリ構成

| ディレクトリ | 用途 |
|---|---|
| `terraform/` | Proxmox VM / LXC のプロビジョニング |
| `ansible/` | Proxmox ホスト OS の設定管理 |
| `k8s/` | k3s クラスター上のアプリデプロイ |
| `packer/` | VM テンプレートのビルド |
| `scripts/` | 補助スクリプト |

## 作業ルール

### ドキュメント
- コマンドや手順は **変更対象のディレクトリにある README.md に必ず記載する**
  - `terraform/` の変更 → `terraform/README.md`
  - `ansible/` の変更 → `ansible/README.md`
  - `k8s/monitoring/` の変更 → `k8s/monitoring/README.md`
  - （以下同様）

### 設定変更
- **手動コマンドは確認のみ許容**。設定変更は必ず Terraform / Ansible / Helm values で行う
- k3s ノードの設定は `terraform/main.tf` の `remote-exec` で管理する。Ansible には記載しない

### Git
- ファイル修正・作成のたびに `git commit && git push` まで実施する
