#!/usr/bin/env bash
# ============================================================
# start-lab.sh - ラボ起動スクリプト
# 実行場所: Raspberry Pi (192.168.210.55)
#
# 実行順序:
#   1. Wake-on-LAN で Proxmox ノードを起動 (MAC 設定済みの場合)
#   2. pve-node01 / pve-node02 / pve-node03 の SSH 接続可能まで待機
#   3. VM を順番に起動: dns-ct → k3s-master → worker01〜07
#   4. k8s 全ノードが Ready になるまで待機
#   5. kubectl uncordon で全 worker ノードをスケジュール可能に復帰
#
# 使い方:
#   bash ~/proxmox-lab/power/scripts/start-lab.sh
# ============================================================

set -euo pipefail

# ============================================================
# 設定
# ============================================================

# Proxmox ノード
NODE01_IP="192.168.210.11"
NODE02_IP="192.168.210.12"
NODE03_IP="192.168.210.13"

# WoL 用 MAC アドレス (未設定の場合は WoL をスキップ)
NODE01_MAC="XX:XX:XX:XX:XX:XX"
NODE02_MAC="XX:XX:XX:XX:XX:XX"
NODE03_MAC="XX:XX:XX:XX:XX:XX"
BROADCAST="192.168.210.255"

# Proxmox 起動待機タイムアウト (秒)
SSH_WAIT_TIMEOUT=300

# VM/LXC IDs
VMID_DNS_CT=101       # LXC (node01) — DNS を最初に起動
VMID_K3S_MASTER=201   # node01
VMID_WORKER01=202     # node01
VMID_WORKER02=203     # node01
VMID_WORKER03=204     # node02
VMID_WORKER04=205     # node02
VMID_WORKER05=206     # node02
VMID_WORKER06=207     # node03
VMID_WORKER07=208     # node03

# k3s-master
K3S_MASTER_IP="192.168.210.21"
K3S_MASTER_USER="ubuntu"

# kubectl uncordon 対象のワーカーノード名
K8S_WORKERS=(k3s-worker01 k3s-worker02 k3s-worker03 k3s-worker04 k3s-worker05 k3s-worker06 k3s-worker07)

# k8s 全ノード Ready 待機タイムアウト (秒)
K8S_READY_TIMEOUT=300

# ログ
LOG_FILE="$HOME/lab-start.log"

# ============================================================
# ユーティリティ
# ============================================================

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

die() {
  log "ERROR: $*"
  exit 1
}

wait_for_ssh() {
  local name="$1"
  local ip="$2"
  local user="${3:-root}"
  local elapsed=0

  log "  $name ($ip) の SSH 接続待機中..."
  while ! ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no \
              -o BatchMode=yes "${user}@${ip}" exit 2>/dev/null; do
    sleep 5
    elapsed=$(( elapsed + 5 ))
    if (( elapsed >= SSH_WAIT_TIMEOUT )); then
      die "$name が ${SSH_WAIT_TIMEOUT}秒以内に起動しませんでした"
    fi
    echo -n "."
  done
  echo ""
  log "  $name 起動確認"
}

# ============================================================
# Wake-on-LAN
# ============================================================

send_wol() {
  local name="$1"
  local mac="$2"
  log "  WoL パケット送信: $name ($mac)"
  if command -v wakeonlan &>/dev/null; then
    wakeonlan -i "$BROADCAST" "$mac"
  elif command -v wol &>/dev/null; then
    wol -i "$BROADCAST" "$mac"
  else
    log "  WARNING: wakeonlan / wol コマンドが見つかりません (apt install wakeonlan)"
  fi
}

wakeup_proxmox() {
  if [[ "$NODE01_MAC" == "XX:XX:XX:XX:XX:XX" ]]; then
    log "  WoL: MAC アドレス未設定のためスキップします"
    log "  (手動で Proxmox を起動してから再実行してください)"
    log "  MAC アドレスの確認: Proxmox ノード上で 'ip link show'"
    log "  設定箇所: power/scripts/start-lab.sh の NODE01_MAC / NODE02_MAC / NODE03_MAC"
  else
    send_wol "pve-node01" "$NODE01_MAC"
    send_wol "pve-node02" "$NODE02_MAC"
    send_wol "pve-node03" "$NODE03_MAC"
  fi
}

# ============================================================
# VM 起動
# ============================================================

start_vm() {
  local node_ip="$1"
  local vmid="$2"
  local name="$3"
  log "  VM 起動: ${name} (VMID: ${vmid})"
  ssh -o BatchMode=yes "root@${node_ip}" "qm start ${vmid}" 2>&1 | tee -a "$LOG_FILE" \
    || die "${name} (VMID: ${vmid}) の起動に失敗しました"
}

start_lxc() {
  local node_ip="$1"
  local vmid="$2"
  local name="$3"
  log "  LXC 起動: ${name} (VMID: ${vmid})"
  ssh -o BatchMode=yes "root@${node_ip}" "pct start ${vmid}" 2>&1 | tee -a "$LOG_FILE" \
    || die "${name} (VMID: ${vmid}) の起動に失敗しました"
}

# ============================================================
# メイン処理
# ============================================================

main() {
  log "=========================================="
  log "ラボ起動シーケンス開始"
  log "=========================================="

  # 1. Wake-on-LAN
  log "[1/5] Proxmox ノード起動 (Wake-on-LAN)..."
  wakeup_proxmox

  # 2. Proxmox SSH 接続待機
  log "[2/5] Proxmox SSH 接続待機..."
  wait_for_ssh "pve-node01" "$NODE01_IP" "root"
  wait_for_ssh "pve-node02" "$NODE02_IP" "root"
  wait_for_ssh "pve-node03" "$NODE03_IP" "root"

  # 3. VM 起動
  log "[3/5] VM 起動..."

  # dns-ct を最初に起動 (DNS が先に動いていると後続の名前解決が安定する)
  start_lxc "$NODE01_IP" "$VMID_DNS_CT" "dns-ct"
  sleep 10

  # k3s-master 起動 → SSH 接続確認まで待機
  start_vm "$NODE01_IP" "$VMID_K3S_MASTER" "k3s-master"
  wait_for_ssh "k3s-master" "$K3S_MASTER_IP" "$K3S_MASTER_USER"
  sleep 15  # k3s API サーバーの起動を待つ

  # worker (node01 / node02 を並行して起動)
  start_vm "$NODE01_IP" "$VMID_WORKER01" "k3s-worker01"
  start_vm "$NODE01_IP" "$VMID_WORKER02" "k3s-worker02"
  start_vm "$NODE02_IP" "$VMID_WORKER03" "k3s-worker03"
  start_vm "$NODE02_IP" "$VMID_WORKER04" "k3s-worker04"
  start_vm "$NODE02_IP" "$VMID_WORKER05" "k3s-worker05"
  start_vm "$NODE03_IP" "$VMID_WORKER06" "k3s-worker06"
  start_vm "$NODE03_IP" "$VMID_WORKER07" "k3s-worker07"

  # 4. k8s 全ノード Ready 待機
  log "[4/5] k8s 全ノード Ready 待機..."
  local elapsed=0
  while true; do
    local not_ready
    not_ready=$(ssh -o BatchMode=yes "${K3S_MASTER_USER}@${K3S_MASTER_IP}" \
      "sudo kubectl get nodes --no-headers 2>/dev/null | grep -cv ' Ready'" \
      2>/dev/null || echo "99")

    if (( not_ready == 0 )); then
      log "  全ノードが Ready です"
      break
    fi

    log "  Not Ready ノード: ${not_ready} 件 (${elapsed}s 経過)"
    sleep 10
    elapsed=$(( elapsed + 10 ))

    if (( elapsed >= K8S_READY_TIMEOUT )); then
      log "  WARNING: ${K8S_READY_TIMEOUT}秒経過。Ready でないノードがありますが uncordon を実行します。"
      break
    fi
  done

  # 5. kubectl uncordon
  log "[5/5] kubectl uncordon..."
  for node in "${K8S_WORKERS[@]}"; do
    log "  uncordon: $node"
    ssh -o BatchMode=yes "${K3S_MASTER_USER}@${K3S_MASTER_IP}" \
      "sudo kubectl uncordon ${node}" 2>&1 | tee -a "$LOG_FILE" \
      || log "  WARNING: ${node} uncordon 失敗 (既にスケジュール可能の可能性)"
  done

  log "=========================================="
  log "ラボ起動完了"
  log "  Proxmox UI : https://${NODE01_IP}:8006"
  log "              https://${NODE02_IP}:8006"
  log "              https://${NODE03_IP}:8006"
  log "=========================================="

  # 最終ノード状態確認
  ssh -o BatchMode=yes "${K3S_MASTER_USER}@${K3S_MASTER_IP}" \
    "sudo kubectl get nodes -o wide" 2>&1 | tee -a "$LOG_FILE" || true
}

main
