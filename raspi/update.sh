#!/bin/bash
# PXE 設定を最新に更新するスクリプト (git pull + initrd パッチ + grub.cfg コピー)
set -euo pipefail

cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
git pull
sudo bash raspi/patch-initrd.sh
sudo cp raspi/grub/grub.cfg /srv/tftp/grub/grub.cfg
echo "=== 更新完了 ==="
