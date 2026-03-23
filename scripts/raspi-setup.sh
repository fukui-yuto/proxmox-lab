#!/bin/bash
# Raspberry Pi 5 (Ubuntu Server) 初期セットアップスクリプト
# 実行: sudo bash scripts/raspi-setup.sh

set -euo pipefail

echo "=== 基本パッケージインストール ==="
apt-get update
apt-get install -y \
  ansible \
  corosync-qnetd \
  wget \
  curl \
  gnupg \
  software-properties-common \
  git

echo "=== HashiCorp リポジトリ追加 (terraform / packer) ==="
wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor --yes -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  > /etc/apt/sources.list.d/hashicorp.list
apt-get update
apt-get install -y terraform packer

echo "=== corosync-qnetd 有効化 ==="
systemctl enable --now corosync-qnetd

echo ""
echo "=== セットアップ完了 ==="
echo "次のステップ:"
echo "  1. NUC 2台に Proxmox VE を USB から手動インストールする"
echo "     node01: IP=192.168.210.11, hostname=pve-node01.local"
echo "     node02: IP=192.168.210.12, hostname=pve-node02.local"
echo "  2. 各ノードに SSH 公開鍵を登録する:"
echo "     ssh-copy-id -i ~/.ssh/id_ed25519.pub root@192.168.210.11"
echo "     ssh-copy-id -i ~/.ssh/id_ed25519.pub root@192.168.210.12"
echo "  3. Ansible でクラスター構築:"
echo "     cd ~/proxmox-lab/ansible && ansible-playbook -i inventory/hosts.yml playbooks/site.yml"
