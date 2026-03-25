#!/usr/bin/env bash
# Proxmox 2台を Wake-on-LAN で起動するスクリプト
#
# 事前準備:
#   1. 各ノードの BIOS/UEFI で Wake-on-LAN を有効化
#   2. 下の MAC アドレスを実際の値に書き換える
#   3. wakeonlan コマンドをインストール:
#      apt install wakeonlan   # Debian/Ubuntu
#      brew install wakeonlan  # macOS
#
# 使い方:
#   bash scripts/proxmox-wakeup.sh           # 両ノード起動
#   bash scripts/proxmox-wakeup.sh node01    # node01 のみ
#   bash scripts/proxmox-wakeup.sh node02    # node02 のみ

set -euo pipefail

# ===== 設定: MAC アドレスをここに記入 =====
NODE01_MAC="XX:XX:XX:XX:XX:XX"   # pve-node01 (192.168.210.11) の MAC アドレス
NODE02_MAC="XX:XX:XX:XX:XX:XX"   # pve-node02 (192.168.210.12) の MAC アドレス
BROADCAST="192.168.210.255"      # ブロードキャストアドレス

NODE01_IP="192.168.210.11"
NODE02_IP="192.168.210.12"
SSH_WAIT_TIMEOUT=180
# ==========================================

# MAC アドレス未設定チェック
check_mac() {
  local name="$1"
  local mac="$2"
  if [[ "$mac" == "XX:XX:XX:XX:XX:XX" ]]; then
    echo "ERROR: $name の MAC アドレスが未設定です。"
    echo "       $0 を編集して MAC アドレスを設定してください。"
    echo ""
    echo "MAC アドレスの確認方法 (Proxmox ノード上で実行):"
    echo "  ip link show"
    exit 1
  fi
}

# WoL コマンド存在チェック
if ! command -v wakeonlan &>/dev/null && ! command -v wol &>/dev/null; then
  echo "ERROR: wakeonlan または wol コマンドが見つかりません。"
  echo "  apt install wakeonlan  または  brew install wakeonlan"
  exit 1
fi

send_wol() {
  local name="$1"
  local mac="$2"
  local ip="$3"

  echo ">>> $name ($ip) に WoL パケットを送信中..."
  if command -v wakeonlan &>/dev/null; then
    wakeonlan -i "$BROADCAST" "$mac"
  else
    wol -i "$BROADCAST" "$mac"
  fi
}

wait_for_ssh() {
  local name="$1"
  local ip="$2"
  local elapsed=0

  echo ">>> $name ($ip) の起動を待機中..."
  while ! ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no \
              -o BatchMode=yes root@"$ip" exit 2>/dev/null; do
    sleep 5
    elapsed=$((elapsed + 5))
    if [[ $elapsed -ge $SSH_WAIT_TIMEOUT ]]; then
      echo "WARNING: $name が ${SSH_WAIT_TIMEOUT}秒以内に起動しませんでした。"
      return 1
    fi
    echo -n "."
  done
  echo ""
  echo ">>> $name が起動しました！"
}

wake_node() {
  local target="$1"
  case "$target" in
    node01)
      check_mac "pve-node01" "$NODE01_MAC"
      send_wol "pve-node01" "$NODE01_MAC" "$NODE01_IP"
      wait_for_ssh "pve-node01" "$NODE01_IP"
      ;;
    node02)
      check_mac "pve-node02" "$NODE02_MAC"
      send_wol "pve-node02" "$NODE02_MAC" "$NODE02_IP"
      wait_for_ssh "pve-node02" "$NODE02_IP"
      ;;
    both)
      check_mac "pve-node01" "$NODE01_MAC"
      check_mac "pve-node02" "$NODE02_MAC"
      send_wol "pve-node01" "$NODE01_MAC" "$NODE01_IP"
      send_wol "pve-node02" "$NODE02_MAC" "$NODE02_IP"
      wait_for_ssh "pve-node01" "$NODE01_IP"
      wait_for_ssh "pve-node02" "$NODE02_IP"
      ;;
  esac
}

TARGET="${1:-both}"

case "$TARGET" in
  node01|node02|both)
    wake_node "$TARGET"
    echo ""
    echo "完了。起動対象: $TARGET"
    ;;
  *)
    echo "使い方: $0 [node01|node02|both]"
    echo "  引数なし → 両ノードを起動"
    exit 1
    ;;
esac
