# Runbook

各ツールの手順は該当ディレクトリの README を参照。

---

## セットアップ手順 (初回)

| ステップ | ドキュメント | 内容 |
|---------|-------------|------|
| 1 | [scripts/README.md](../scripts/README.md) | Raspberry Pi セットアップ・Proxmox インストール |
| 2 | [ansible/README.md](../ansible/README.md) | Ansible でクラスター構築 |
| 3 | [packer/README.md](../packer/README.md) | Ubuntu VM テンプレートビルド |
| 4 | [terraform/README.md](../terraform/README.md) | VM / LXC コンテナデプロイ |

---

## 日常運用

| 操作 | コマンド |
|------|---------|
| **ノード起動** | `bash scripts/proxmox-wakeup.sh` |
| **クラスターシャットダウン** | `ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/shutdown.yml` |
| **Ansible 疎通確認** | `ansible -i ansible/inventory/hosts.yml proxmox -m ping` |
