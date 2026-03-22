#!/bin/bash
# Proxmox initrd に ISO を埋め込むスクリプト
# initrd の init スクリプトは /proxmox.iso が存在すればそれを使う仕組みがあるため、
# ISO を直接 initrd に含めることで PXE ブートが可能になる
set -euo pipefail

INITRD_ORIG="/srv/pxe/iso/boot/initrd.img"
INITRD_PATCHED="/srv/pxe/iso/boot/initrd-pxe.img"
WORK_DIR="/tmp/initrd-patch"
ISO_SRC="/tmp/proxmox-ve.iso"

if [ ! -s "$ISO_SRC" ]; then
  echo "ERROR: $ISO_SRC が見つかりません。setup.sh を先に実行してください。"
  exit 1
fi

echo "=== initrd を展開 ==="
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"
zstd -d "$INITRD_ORIG" -o initrd.cpio --force
cpio -idm < initrd.cpio 2>/dev/null
rm initrd.cpio

echo "=== ISO を initrd に埋め込み ($(du -sh "$ISO_SRC" | cut -f1)) ==="
cp "$ISO_SRC" proxmox.iso

echo "=== initrd を再パック (zstd -5) ==="
find . | cpio -o -H newc 2>/dev/null | zstd -5 -o "$INITRD_PATCHED" --force
echo "パッチ済み initrd: $INITRD_PATCHED ($(du -sh "$INITRD_PATCHED" | cut -f1))"
