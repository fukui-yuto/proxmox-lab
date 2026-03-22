#!/bin/bash
# PXE 設定を最新に更新するスクリプト
set -euo pipefail

cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
git pull
sudo bash raspi/patch-initrd.sh
sudo cp raspi/ipxe/boot.ipxe /srv/pxe/boot.ipxe
sudo cp raspi/dnsmasq/pxe.conf /etc/dnsmasq.d/pxe.conf
sudo cp raspi/nginx/pve-install.conf /etc/nginx/sites-available/pve-install
sudo systemctl restart dnsmasq nginx
echo "=== 更新完了 ==="
