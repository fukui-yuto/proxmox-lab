#!/usr/bin/env bash
# ============================================================
# shutdown-lab.sh - ラボシャットダウンスクリプト
# 実行場所: Raspberry Pi (192.168.210.55)
#
# 使い方:
#   bash ~/proxmox-lab/power/scripts/shutdown-lab.sh
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ANSIBLE_DIR="$(cd "${SCRIPT_DIR}/../../ansible" && pwd)"

cd "$ANSIBLE_DIR"
exec ansible-playbook -i inventory/hosts.yml ../power/ansible/shutdown.yml -e confirm=yes
