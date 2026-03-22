#!/bin/bash
# Raspberry Pi 5 (Ubuntu Server) 初期セットアップスクリプト
# 実行: sudo bash setup.sh

set -euo pipefail

RASPI_IP="192.168.210.55"
# Proxmox VE ISO: 最新版は https://www.proxmox.com/en/downloads で確認
PVE_ISO_URL="https://enterprise.proxmox.com/iso/proxmox-ve_8.4-1.iso"
PVE_ISO_NAME="proxmox-ve.iso"
TFTP_ROOT="/srv/tftp"
HTTP_ROOT="/srv/pxe"

echo "=== 基本パッケージインストール ==="
apt-get update
apt-get install -y \
  dnsmasq \
  nginx \
  ansible \
  corosync-qnetd \
  wget \
  curl \
  gnupg \
  software-properties-common \
  p7zip-full \
  git

echo "=== HashiCorp リポジトリ追加 (terraform / packer) ==="
wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor --yes -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  > /etc/apt/sources.list.d/hashicorp.list
apt-get update
apt-get install -y terraform packer

echo "=== ディレクトリ作成 ==="
mkdir -p "$TFTP_ROOT"/{grub,pxelinux.cfg}
mkdir -p "$HTTP_ROOT"/{iso,answer}
mkdir -p /etc/dnsmasq.d

echo "=== dnsmasq 設定 ==="
cp "$(dirname "$0")/dnsmasq/pxe.conf" /etc/dnsmasq.d/pxe.conf
systemctl restart dnsmasq
systemctl enable dnsmasq

echo "=== nginx 設定 ==="
cp "$(dirname "$0")/nginx/pve-install.conf" /etc/nginx/sites-available/pve-install
ln -sf /etc/nginx/sites-available/pve-install /etc/nginx/sites-enabled/pve-install
rm -f /etc/nginx/sites-enabled/default
systemctl restart nginx
systemctl enable nginx

echo "=== Proxmox ISO ダウンロード・展開 ==="
if [ ! -s "/tmp/$PVE_ISO_NAME" ]; then
  rm -f "/tmp/$PVE_ISO_NAME"
  wget -O "/tmp/$PVE_ISO_NAME" "$PVE_ISO_URL"
fi
7z x "/tmp/$PVE_ISO_NAME" -o"$HTTP_ROOT/iso" -y
cp -r "$HTTP_ROOT/iso/boot/grub" "$TFTP_ROOT/"

echo "=== grub PXE 設定コピー ==="
cp "$(dirname "$0")/grub/grub.cfg" "$TFTP_ROOT/grub/grub.cfg"

echo "=== answer.toml に SSH 公開鍵を自動注入して配信ディレクトリにコピー ==="
SSH_PUBKEY=$(cat /home/"${SUDO_USER:-$USER}"/.ssh/id_ed25519.pub 2>/dev/null || cat ~/.ssh/id_ed25519.pub)
if [ -z "$SSH_PUBKEY" ]; then
  echo "ERROR: ~/.ssh/id_ed25519.pub が見つかりません。先に ssh-keygen を実行してください。"
  exit 1
fi
for NODE in node01 node02; do
  ANSWER_SRC="$(dirname "$0")/../install/answer-${NODE}.toml"
  ANSWER_DST="$HTTP_ROOT/answer/${NODE}.toml"
  # ssh_keys の行を実際の公開鍵で置き換え
  sed "s|ssh-ed25519 AAAA... your-public-key-here|${SSH_PUBKEY}|g" "$ANSWER_SRC" > "$ANSWER_DST"
  echo "  → $ANSWER_DST に公開鍵を注入しました"
done

echo "=== corosync-qnetd 有効化 ==="
systemctl enable --now corosync-qnetd

echo ""
echo "=== セットアップ完了 ==="
echo "次のステップ:"
echo "  1. install/answer-*.toml の root_password を確認・変更する"
echo "  2. NUC の BIOS で Network Boot (PXE) を最優先に設定する"
echo "  3. NUC を起動する → Proxmox が自動インストールされる"
echo "  4. インストール完了後: cd ~/proxmox-lab/ansible && ansible-playbook -i inventory/hosts.yml playbooks/site.yml"
