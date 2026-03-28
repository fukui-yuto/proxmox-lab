# Monitoring — Prometheus + Grafana

k3s クラスター上に `kube-prometheus-stack` を使ってメトリクス監視基盤を構築する。

## 構成

```
Prometheus      ← メトリクス収集 (node_exporter / kube-state-metrics)
Alertmanager    ← アラート通知
Grafana         ← ダッシュボード可視化 (http://grafana.homelab.local)
```

## 前提条件

- k3s クラスターが稼働していること
- `kubectl` が k3s クラスターに接続できること
- `helm` v3 がインストールされていること

### kubectl のインストール

```bash
sudo snap install kubectl --classic
```

### kubectl の kubeconfig 設定

> **注意:** k3s クラスターをデプロイした後に実施する。

k3s-master から kubeconfig をコピーして接続設定を行う。

```bash
# kubeconfig ディレクトリ作成
mkdir -p ~/.kube

# k3s-master から kubeconfig をコピー
scp ubuntu@192.168.211.21:/etc/rancher/k3s/k3s.yaml ~/.kube/config

# アドレスを 127.0.0.1 → k3s-master の IP に書き換え
sed -i 's/127.0.0.1/192.168.211.21/g' ~/.kube/config
```

### 接続確認

> **注意:** k3s クラスターをデプロイした後に実施する。

```bash
# kubectl 接続確認
kubectl get nodes

# helm バージョン確認
helm version
```

## デプロイ手順

Raspberry Pi 上で実行する。

```bash
cd ~/proxmox-lab/k8s/monitoring

bash install.sh
```

### 手動で実行する場合

```bash
# Helm リポジトリ追加
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Namespace 作成
kubectl apply -f namespace.yaml

# デプロイ
helm upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --version 61.3.2 \
  --values values.yaml \
  --timeout 10m \
  --wait

# ダッシュボード ConfigMap 適用
kubectl apply -f dashboards/
```

## アクセス

### Grafana

| 項目 | 値 |
|------|-----|
| URL | http://grafana.homelab.local |
| ユーザー | `admin` |
| 初期パスワード | `values.yaml` の `grafana.adminPassword` を参照 |

> **注意:** 初回ログイン後に必ずパスワードを変更すること。

Ingress は Traefik 経由で `192.168.211.21` (k3s-master) の 80 番ポートで公開されている。
`192.168.211.22` / `23` (worker) の IP も ADDRESS に表示されるが、master への疎通のみで十分。

#### Windows PC からのアクセス設定

管理者権限の PowerShell で以下を実行する。

```powershell
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.211.21  grafana.homelab.local"
```

または `C:\Windows\System32\drivers\etc\hosts` を管理者権限のエディタで開き、以下を追記する。

```
192.168.211.21  grafana.homelab.local
```

### Prometheus (ポートフォワード)

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
# http://localhost:9090
```

### Alertmanager (ポートフォワード)

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093
# http://localhost:9093
```

## ダッシュボード

`dashboards/` ディレクトリに ConfigMap として管理している。Grafana の sidecar が自動的に読み込む (`grafana_dashboard: "1"` ラベルを使用)。

| ファイル | ダッシュボード名 | 内容 |
|---|---|---|
| `homelab-overview-cm.yaml` | Homelab Overview | 全ノードの CPU・メモリ・ディスク・ネットワーク概要 |
| `k3s-cluster-cm.yaml` | k3s Cluster | Pod 状態・CPU/メモリ Top10・Pod 一覧テーブル |

ダッシュボードを追加・更新した場合は再 apply する。

```bash
kubectl apply -f dashboards/
```

## worker03 が監視対象に表示されない場合

worker03 (192.168.211.24) は pve-node02 上にあり、VLAN10 が L2 未接続のため
master/worker01/worker02 から直接 ARP 解決できない。
Prometheus が `no route to host` エラーでスクレイプに失敗する場合は、
逆方向ルートを追加する。

`terraform/main.tf` に master・worker01・worker02 の `remote-exec` でルートを設定している。
既存 VM に適用するには `-replace` で再作成する。

```bash
cd ~/proxmox-lab/terraform
terraform apply -replace=proxmox_virtual_environment_vm.k3s_master \
                -replace='proxmox_virtual_environment_vm.k3s_worker[0]' \
                -replace='proxmox_virtual_environment_vm.k3s_worker[1]'
```

> **注意:** VM が再作成されるため k3s のセットアップも再実行が必要。
> 既存 VM を壊したくない場合は以下で直接適用する（一時対応）。
>
> ```bash
> for ip in 192.168.211.21 192.168.211.22 192.168.211.23; do
>   ssh ubuntu@${ip} "sudo tee /etc/netplan/99-worker03-route.yaml > /dev/null <<'EOF'
> network:
>   version: 2
>   ethernets:
>     eth0:
>       routes:
>         - to: 192.168.211.24/32
>           via: 192.168.211.1
> EOF
> sudo chmod 600 /etc/netplan/99-worker03-route.yaml && sudo netplan apply"
> done
> ```

適用後、Prometheus ターゲットを確認する。

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 &
sleep 3 && curl -s http://localhost:9090/api/v1/targets | python3 -c "import sys,json;[print(t['scrapeUrl'],t['health']) for t in json.load(sys.stdin)['data']['activeTargets'] if '192.168.211.24' in t.get('scrapeUrl','')]"
```

全ターゲットが `up` になれば Grafana ダッシュボードに worker03 が表示される。

## 動作確認

```bash
# Pod の状態確認
kubectl get pods -n monitoring

# 全 Pod が Running になっていれば OK
NAME                                                   READY   STATUS    RESTARTS
kube-prometheus-stack-grafana-xxx                      3/3     Running   0
kube-prometheus-stack-prometheus-0                     2/2     Running   0
kube-prometheus-stack-alertmanager-0                   2/2     Running   0
kube-prometheus-stack-operator-xxx                     1/1     Running   0
kube-prometheus-stack-kube-state-metrics-xxx           1/1     Running   0
kube-prometheus-stack-prometheus-node-exporter-xxx     1/1     Running   0  (各ノード)
```

## Alertmanager の通知設定

`values.yaml` の `alertmanager.config.receivers` に Slack の Webhook URL を設定する。

```yaml
receivers:
  - name: slack
    slack_configs:
      - api_url: "https://hooks.slack.com/services/YOUR/WEBHOOK/URL"
        channel: "#alerts"
        send_resolved: true
```

設定後に再デプロイ:

```bash
helm upgrade kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values values.yaml
```

## アンインストール

```bash
helm uninstall kube-prometheus-stack -n monitoring
kubectl delete namespace monitoring
```

## 次のステップ

Phase 2 で Elasticsearch + Fluent Bit を追加した後、`values.yaml` の以下のコメントを外すと Grafana でログも確認できる。

```yaml
grafana:
  additionalDataSources:
    - name: Elasticsearch
      type: elasticsearch
      url: http://elasticsearch.elasticsearch.svc.cluster.local:9200
      ...
```
