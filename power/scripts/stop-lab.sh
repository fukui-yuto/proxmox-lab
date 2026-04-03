#!/usr/bin/env bash
# ============================================================
# stop-lab.sh - ラボ自動停止スクリプト
# 実行場所: pve-node01 (systemd timer により 5 分ごとに起動)
#
# 動作概要:
#   アイドル状態が 12 回連続 (= 60 分) 継続した場合に停止処理を実行する。
#   アイドル判定条件 (全て満たす必要あり):
#     - pve-node01 / pve-node02 / pve-node03 の CPU アイドル率 >= CPU_IDLE_THRESHOLD
#     - vmbr0 のネットワーク使用量 <= NET_THRESHOLD_KB KB/s
#     - pve-node01 へのログインセッションが 0
#
# 停止順序:
#   1. kubectl drain (k3s worker01〜07)
#   2. worker VM 停止 (202/203 on node01, 204/205/206 on node02, 207/208 on node03)
#   3. k3s-master VM 停止 (201)
#   4. dns-ct LXC 停止 (101)
#   5. pve-node02 / pve-node03 poweroff (SSH 経由)
#   6. pve-node01 (自身) poweroff
#
# オプション:
#   --dry-run  実際の停止処理を行わず、アイドル判定結果のみ表示する
# ============================================================

set -euo pipefail

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
fi

# ============================================================
# 設定
# ============================================================

# Proxmox ノード
NODE02_IP="192.168.210.12"
NODE03_IP="192.168.210.13"

# VM/LXC IDs (pve-node01)
VMID_K3S_MASTER=201
VMID_WORKER01=202
VMID_WORKER02=203
VMID_DNS_CT=101       # LXC

# VM IDs (pve-node02)
VMID_WORKER03=204
VMID_WORKER04=205
VMID_WORKER05=206

# VM IDs (pve-node03)
VMID_WORKER06=207
VMID_WORKER07=208

# k3s-master へのアクセス
K3S_MASTER_IP="192.168.210.21"
K3S_MASTER_USER="ubuntu"

# kubectl drain 対象のワーカーノード名
K8S_WORKERS=(k3s-worker01 k3s-worker02 k3s-worker03 k3s-worker04 k3s-worker05 k3s-worker06 k3s-worker07)

# アイドル閾値
CPU_IDLE_THRESHOLD=95    # CPU アイドル率 (%) この値以上でアイドルとみなす
NET_THRESHOLD_KB=500     # ネットワーク使用量 (KB/s) この値以下でアイドルとみなす
NET_INTERFACE="vmbr0"   # 監視するネットワークインターフェース

# 連続アイドル判定回数 (5 分 × 12 = 60 分)
REQUIRED_IDLE_CHECKS=12

# VM 停止タイムアウト (秒)
VM_SHUTDOWN_TIMEOUT=120

# 状態・ログ
STATE_DIR="/var/lib/lab-idle-shutdown"
STATE_FILE="${STATE_DIR}/idle_count"
LOG_FILE="/var/log/lab-idle-shutdown.log"
LOCK_FILE="/var/run/lab-idle-shutdown.lock"

# ============================================================
# ユーティリティ
# ============================================================

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

die() {
  log "ERROR: $*"
  release_lock
  exit 1
}

acquire_lock() {
  if [[ -f "$LOCK_FILE" ]]; then
    local pid
    pid=$(cat "$LOCK_FILE")
    if kill -0 "$pid" 2>/dev/null; then
      log "既に実行中 (PID: $pid)。スキップします。"
      exit 0
    fi
    log "古いロックファイルを削除します (PID: $pid は存在しない)"
  fi
  echo $$ > "$LOCK_FILE"
}

release_lock() {
  rm -f "$LOCK_FILE"
}

# ============================================================
# アイドル検知
# ============================================================

# CPU アイドル率 (%) を返す
# 引数: "local" または SSH 接続先 IP
get_cpu_idle_percent() {
  local target="$1"
  # /proc/stat の cpu 行から idle 率を計算
  local cmd='awk "/^cpu /{idle=\$5; total=\$2+\$3+\$4+\$5+\$6+\$7+\$8; print int(idle*100/total)}" /proc/stat'
  if [[ "$target" == "local" ]]; then
    eval "$cmd"
  else
    ssh -o ConnectTimeout=5 -o BatchMode=yes "root@${target}" "$cmd" 2>/dev/null || echo "0"
  fi
}

# ネットワーク使用量 (KB/s) を返す — 1 秒間の RX + TX 差分
get_network_kb() {
  local iface="$1"
  local rx1 tx1 rx2 tx2
  rx1=$(awk "/^ *${iface}:/{print \$2}" /proc/net/dev 2>/dev/null || echo 0)
  tx1=$(awk "/^ *${iface}:/{print \$10}" /proc/net/dev 2>/dev/null || echo 0)
  sleep 1
  rx2=$(awk "/^ *${iface}:/{print \$2}" /proc/net/dev 2>/dev/null || echo 0)
  tx2=$(awk "/^ *${iface}:/{print \$10}" /proc/net/dev 2>/dev/null || echo 0)
  echo $(( (rx2 - rx1 + tx2 - tx1) / 1024 ))
}

# アイドル状態かどうか確認する
# 全条件を満たす場合は return 0、1 つでも満たさない場合は return 1
check_idle() {
  local is_idle=true

  # CPU チェック (node01)
  local cpu_idle_node01
  cpu_idle_node01=$(get_cpu_idle_percent "local")
  log "  CPU アイドル率 node01: ${cpu_idle_node01}%"
  if (( cpu_idle_node01 < CPU_IDLE_THRESHOLD )); then
    log "  -> 非アイドル: node01 CPU idle ${cpu_idle_node01}% < ${CPU_IDLE_THRESHOLD}%"
    is_idle=false
  fi

  # CPU チェック (node02)
  local cpu_idle_node02
  cpu_idle_node02=$(get_cpu_idle_percent "$NODE02_IP")
  log "  CPU アイドル率 node02: ${cpu_idle_node02}%"
  if (( cpu_idle_node02 < CPU_IDLE_THRESHOLD )); then
    log "  -> 非アイドル: node02 CPU idle ${cpu_idle_node02}% < ${CPU_IDLE_THRESHOLD}%"
    is_idle=false
  fi

  # CPU チェック (node03)
  local cpu_idle_node03
  cpu_idle_node03=$(get_cpu_idle_percent "$NODE03_IP")
  log "  CPU アイドル率 node03: ${cpu_idle_node03}%"
  if (( cpu_idle_node03 < CPU_IDLE_THRESHOLD )); then
    log "  -> 非アイドル: node03 CPU idle ${cpu_idle_node03}% < ${CPU_IDLE_THRESHOLD}%"
    is_idle=false
  fi

  # ネットワークチェック
  local net_kb
  net_kb=$(get_network_kb "$NET_INTERFACE")
  log "  ネットワーク使用量: ${net_kb} KB/s"
  if (( net_kb > NET_THRESHOLD_KB )); then
    log "  -> 非アイドル: ネットワーク ${net_kb} KB/s > ${NET_THRESHOLD_KB} KB/s"
    is_idle=false
  fi

  # ログインセッションチェック (pve-node01 自身)
  local sessions
  sessions=$(who | wc -l)
  log "  ログインセッション数: ${sessions}"
  if (( sessions > 0 )); then
    log "  -> 非アイドル: ログインセッションあり (${sessions})"
    is_idle=false
  fi

  if $is_idle; then
    log "  -> 全条件アイドル"
    return 0
  else
    return 1
  fi
}

# ============================================================
# アイドルカウンタ管理
# ============================================================

get_idle_count() {
  mkdir -p "$STATE_DIR"
  if [[ -f "$STATE_FILE" ]]; then
    cat "$STATE_FILE"
  else
    echo 0
  fi
}

set_idle_count() {
  mkdir -p "$STATE_DIR"
  echo "$1" > "$STATE_FILE"
}

# ============================================================
# 停止処理
# ============================================================

drain_k8s_workers() {
  log "k8s worker ノードを drain します..."
  for node in "${K8S_WORKERS[@]}"; do
    log "  drain: $node"
    ssh -o ConnectTimeout=10 -o BatchMode=yes "${K3S_MASTER_USER}@${K3S_MASTER_IP}" \
      "sudo kubectl drain ${node} --ignore-daemonsets --delete-emptydir-data --timeout=60s" \
      2>&1 | tee -a "$LOG_FILE" \
      || die "kubectl drain ${node} に失敗しました"
  done
  log "  worker drain 完了"
}

shutdown_vm_node01() {
  local vmid="$1"
  local name="$2"
  log "  VM 停止: ${name} (VMID: ${vmid}, node01)"
  qm shutdown "$vmid" --timeout "$VM_SHUTDOWN_TIMEOUT" 2>&1 | tee -a "$LOG_FILE" \
    || die "${name} の停止に失敗しました"
}

shutdown_vm_node02() {
  local vmid="$1"
  local name="$2"
  log "  VM 停止: ${name} (VMID: ${vmid}, node02)"
  ssh -o ConnectTimeout=10 -o BatchMode=yes "root@${NODE02_IP}" \
    "qm shutdown ${vmid} --timeout ${VM_SHUTDOWN_TIMEOUT}" 2>&1 | tee -a "$LOG_FILE" \
    || die "${name} の停止に失敗しました"
}

shutdown_vm_node03() {
  local vmid="$1"
  local name="$2"
  log "  VM 停止: ${name} (VMID: ${vmid}, node03)"
  ssh -o ConnectTimeout=10 -o BatchMode=yes "root@${NODE03_IP}" \
    "qm shutdown ${vmid} --timeout ${VM_SHUTDOWN_TIMEOUT}" 2>&1 | tee -a "$LOG_FILE" \
    || die "${name} の停止に失敗しました"
}

wait_vm_stopped() {
  local vmid="$1"
  local name="$2"
  local elapsed=0
  while qm status "$vmid" 2>/dev/null | grep -q "running"; do
    sleep 5
    elapsed=$(( elapsed + 5 ))
    if (( elapsed >= VM_SHUTDOWN_TIMEOUT )); then
      log "  WARNING: ${name} が ${VM_SHUTDOWN_TIMEOUT}秒で停止しなかったため強制停止します"
      qm stop "$vmid" 2>&1 | tee -a "$LOG_FILE" || true
      return
    fi
  done
  log "  ${name} 停止確認"
}

perform_shutdown() {
  if $DRY_RUN; then
    log "[DRY-RUN] 停止処理をスキップします (実際の停止は行いません)"
    return
  fi

  log "=========================================="
  log "ラボ自動停止シーケンス開始"
  log "=========================================="

  # 1. k8s worker drain
  drain_k8s_workers

  # 2. worker VM 停止 (shutdown 送信のみ、完了待ちは後で)
  log "worker VM 停止..."
  shutdown_vm_node01 "$VMID_WORKER01" "k3s-worker01"
  shutdown_vm_node01 "$VMID_WORKER02" "k3s-worker02"
  shutdown_vm_node02 "$VMID_WORKER03" "k3s-worker03"
  shutdown_vm_node02 "$VMID_WORKER04" "k3s-worker04"
  shutdown_vm_node02 "$VMID_WORKER05" "k3s-worker05"
  shutdown_vm_node03 "$VMID_WORKER06" "k3s-worker06"
  shutdown_vm_node03 "$VMID_WORKER07" "k3s-worker07"

  # node01 の worker 停止完了を待機
  wait_vm_stopped "$VMID_WORKER01" "k3s-worker01"
  wait_vm_stopped "$VMID_WORKER02" "k3s-worker02"

  # 3. k3s-master VM 停止
  log "k3s-master 停止..."
  shutdown_vm_node01 "$VMID_K3S_MASTER" "k3s-master"
  wait_vm_stopped "$VMID_K3S_MASTER" "k3s-master"

  # 4. dns-ct LXC 停止
  log "dns-ct 停止..."
  pct shutdown "$VMID_DNS_CT" --timeout "$VM_SHUTDOWN_TIMEOUT" 2>&1 | tee -a "$LOG_FILE" \
    || die "dns-ct (VMID: ${VMID_DNS_CT}) の停止に失敗しました"

  # 5. pve-node02 / pve-node03 poweroff
  log "pve-node02 を poweroff します..."
  ssh -o ConnectTimeout=10 -o BatchMode=yes "root@${NODE02_IP}" "poweroff" \
    2>&1 | tee -a "$LOG_FILE" \
    || log "  WARNING: pve-node02 への poweroff 送信に失敗 (既に停止している可能性)"

  log "pve-node03 を poweroff します..."
  ssh -o ConnectTimeout=10 -o BatchMode=yes "root@${NODE03_IP}" "poweroff" \
    2>&1 | tee -a "$LOG_FILE" \
    || log "  WARNING: pve-node03 への poweroff 送信に失敗 (既に停止している可能性)"

  # 6. pve-node01 (自身) poweroff
  log "60 秒後に pve-node01 を poweroff します..."
  set_idle_count 0
  release_lock
  sleep 60

  log "=========================================="
  log "pve-node01 poweroff"
  log "=========================================="
  poweroff
}

# ============================================================
# メイン
# ============================================================

main() {
  mkdir -p "$(dirname "$LOG_FILE")"
  acquire_lock
  trap release_lock EXIT

  log "-- アイドルチェック開始 --"

  if check_idle; then
    local count
    count=$(get_idle_count)
    count=$(( count + 1 ))
    set_idle_count "$count"
    log "アイドルカウント: ${count}/${REQUIRED_IDLE_CHECKS}"

    if (( count >= REQUIRED_IDLE_CHECKS )); then
      log "アイドル状態が 1 時間継続。停止処理を開始します。"
      set_idle_count 0
      perform_shutdown
    fi
  else
    set_idle_count 0
    log "アイドルカウントをリセットしました"
  fi

  release_lock
  trap - EXIT
}

main
