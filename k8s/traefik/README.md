# Traefik 設定

k3s 組み込みの Traefik Ingress Controller の設定オーバーライド。

## ファイル構成

| ファイル | 用途 |
|---------|------|
| `helmchartconfig.yaml` | k3s HelmChartConfig — Traefik の externalIPs を設定 |

## servicelb (klipper-lb) 無効化の背景

### 問題

k3s デフォルトの `servicelb` (klipper-lb) と Cilium kube-proxy replacement が競合し、**全ノードの port 80/443 が外部から到達不能**になる。

**原因:**
1. klipper-lb は各ノードに `svclb-traefik` DaemonSet Pod を配置し、HostPort 80/443 を確保する
2. Cilium kube-proxy replacement は HostPort を BPF (TCX) で処理し、パケットを svclb Pod に直接リダイレクトする
3. svclb Pod 内の iptables PREROUTING (`DNAT → Traefik ClusterIP`) は、Cilium の BPF が介入するため発火しない
4. 結果として Traefik に到達できず port 80 が CLOSED になる

NodePort (31939) は svclb を経由しないため正常動作する。

### 解決策

1. **Traefik HelmChartConfig で `spec.externalIPs` を設定** — Cilium が各ノード IP を直接 BPF で処理できるようにする
2. **k3s servicelb を無効化** (`/etc/rancher/k3s/config.yaml.d/01-disable-servicelb.yaml`) — HostPort の競合を排除
3. svclb Pod 削除後、Cilium の ExternalIP BPF ルールが port 80 を Traefik に直接転送する

### 適用手順 (Terraform)

```bash
# Raspberry Pi 上で実行
cd ~/proxmox-lab/terraform
git pull
terraform apply -target=null_resource.k3s_disable_servicelb
```

`terraform apply` が完了すると:
- k3s master が再起動し servicelb が無効化される
- svclb-traefik DaemonSet が自動削除される
- Traefik service に `spec.externalIPs` (全ノード IP) が設定される
- Cilium が ExternalIP BPF エントリを作成し port 80 が疎通可能になる

## ノード IP 一覧 (externalIPs)

| IP | ノード |
|----|--------|
| 192.168.210.21 | k3s-master |
| 192.168.210.24 | k3s-worker03 |
| 192.168.210.25 | k3s-worker04 |
| 192.168.210.26 | k3s-worker05 |
| 192.168.210.27 | k3s-worker06 |
| 192.168.210.28 | k3s-worker07 |
| 192.168.210.30 | k3s-worker09 |
| 192.168.210.31 | k3s-worker10 |
| 192.168.210.32 | k3s-worker11 |
