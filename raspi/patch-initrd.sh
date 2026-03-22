#!/bin/bash
# Proxmox initrd に PXE ネットワークフェッチ機能を追加するスクリプト
set -euo pipefail

INITRD_ORIG="/srv/pxe/iso/boot/initrd.img"
INITRD_PATCHED="/srv/pxe/iso/boot/initrd-pxe.img"
WORK_DIR="/tmp/initrd-patch"

echo "=== initrd を展開 ==="
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"
zstd -d "$INITRD_ORIG" -o initrd.cpio --force
cpio -idm < initrd.cpio 2>/dev/null

echo "=== init スクリプトにネットワーク取得コードを挿入 ==="
LINE=$(grep -n 'initrdisoimage="/proxmox.iso"' init | cut -d: -f1)
echo "挿入位置: line $LINE"

head -n $((LINE - 1)) init > init.new
cat >> init.new << 'PATCH'
# === PXE: fetch= パラメーターで ISO をダウンロード ===
FETCH_URL=""
for _param in $(cat /proc/cmdline); do
    case "$_param" in
        fetch=*) FETCH_URL="${_param#fetch=}" ;;
    esac
done
if [ -n "$FETCH_URL" ]; then
    echo "PXE ブート検出: ISO を取得します..."
    # ネットワークインターフェースを起動
    for _iface in $(ls /sys/class/net/ | grep -v lo); do
        ip link set "$_iface" up 2>/dev/null || true
    done
    # IP アドレスがなければ DHCP で取得
    for _iface in $(ls /sys/class/net/ | grep -v lo | head -1); do
        if ! ip addr show "$_iface" 2>/dev/null | grep -q "inet "; then
            udhcpc -i "$_iface" -t 10 -n -q 2>/dev/null || true
        fi
    done
    echo "ISO ダウンロード中: $FETCH_URL"
    wget -O /proxmox.iso "$FETCH_URL"
    echo "ISO ダウンロード完了"
fi
# === PXE fetch end ===
PATCH
tail -n +"$LINE" init >> init.new
mv init.new init
chmod +x init

echo "=== initrd を再パック (zstd) ==="
find . | cpio -o -H newc 2>/dev/null | zstd -o "$INITRD_PATCHED" --force
echo "パッチ済み initrd: $INITRD_PATCHED"
