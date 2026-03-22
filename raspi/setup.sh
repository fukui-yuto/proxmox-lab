#!/bin/bash
# Raspberry Pi 5 (Ubuntu Server) 初期セットアップスクリプト
# 実行: sudo bash setup.sh

set -euo pipefail

RASPI_IP="192.168.210.55"
PVE_ISO_URL="https://enterprise.proxmox.com/iso/proxmox-ve_8.3-1.iso"  # 最新版に変更すること
PVE_ISO_NAME="proxmox-ve.iso"
TFTP_ROOT="/srv/tftp"
HTTP_ROOT="/srv/pxe"

echo "=== パッケージインストール ==="
apt-get update
apt-get install -y \
  dnsmasq \
  nginx \
  ansible \
  terraform \
  packer \
  corosync-qnetd \
  wget \
  p7zip-full \
  git

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
if [ ! -f "/tmp/$PVE_ISO_NAME" ]; then
  wget -O "/tmp/$PVE_ISO_NAME" "$PVE_ISO_URL"
fi
7z x "/tmp/$PVE_ISO_NAME" -o"$HTTP_ROOT/iso" -y
cp -r "$HTTP_ROOT/iso/boot/grub" "$TFTP_ROOT/"

echo "=== grub PXE 設定コピー ==="
cp "$(dirname "$0")/grub/grub.cfg" "$TFTP_ROOT/grub/grub.cfg"

echo "=== answer.toml を配信ディレクトリにコピー ==="
cp "$(dirname "$0")/../install/answer-node01.toml" "$HTTP_ROOT/answer/node01.toml"
cp "$(dirname "$0")/../install/answer-node02.toml" "$HTTP_ROOT/answer/node02.toml"

echo "=== corosync-qnetd 有効化 ==="
systemctl enable --now corosync-qnetd

echo ""
echo "=== セットアップ完了 ==="
echo "次のステップ:"
echo "  1. raspi/install/answer-node01.toml の MAC アドレスを NUC の MAC に書き換える"
echo "  2. NUC を PXE ブートで起動する"
echo "  3. インストール完了後: cd ansible && ansible-playbook playbooks/site.yml"
