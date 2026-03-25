# k8s — k3s クラスター構築手順

Terraform で VM を作成した後、k3s をインストールしてクラスターを構成する。

## 前提条件

- k3s VM (master / worker01 / worker02 / worker03) が起動していること
- Raspberry Pi から各 VM に SSH 接続できること

```bash
# 疎通確認
ping -c 2 192.168.211.21  # k3s-master   (pve-node01)
ping -c 2 192.168.211.22  # k3s-worker01 (pve-node01)
ping -c 2 192.168.211.23  # k3s-worker02 (pve-node01)
ping -c 2 192.168.211.24  # k3s-worker03 (pve-node02)
```

---

## 1. k3s マスターのインストール

```bash
ssh ubuntu@192.168.211.21 "curl -sfL https://get.k3s.io | sh -"
```

インストール完了を確認する。

```bash
ssh ubuntu@192.168.211.21 "sudo systemctl status k3s"
ssh ubuntu@192.168.211.21 "sudo kubectl get nodes"
```

`STATUS: Ready` になれば OK。

---

## 2. ワーカーノードの参加

マスターのトークンを取得してワーカーに渡す。

```bash
# トークン取得
TOKEN=$(ssh ubuntu@192.168.211.21 "sudo cat /var/lib/rancher/k3s/server/node-token")

# worker01 を参加
ssh ubuntu@192.168.211.22 "curl -sfL https://get.k3s.io | K3S_URL=https://192.168.211.21:6443 K3S_TOKEN=${TOKEN} sh -"

# worker02 を参加
ssh ubuntu@192.168.211.23 "curl -sfL https://get.k3s.io | K3S_URL=https://192.168.211.21:6443 K3S_TOKEN=${TOKEN} sh -"

# worker03 を参加 (pve-node02)
ssh ubuntu@192.168.211.24 "curl -sfL https://get.k3s.io | K3S_URL=https://192.168.211.21:6443 K3S_TOKEN=${TOKEN} sh -"
```

全ノードが Ready になっていることを確認する。

```bash
ssh ubuntu@192.168.211.21 "sudo kubectl get nodes"
```

出力例:
```
NAME           STATUS   ROLES                  AGE   VERSION
k3s-master     Ready    control-plane,master   5m    v1.31.x+k3s1
k3s-worker01   Ready    <none>                 3m    v1.31.x+k3s1
k3s-worker02   Ready    <none>                 2m    v1.31.x+k3s1
k3s-worker03   Ready    <none>                 1m    v1.31.x+k3s1
```

---

## 3. kubeconfig の設定 (Raspberry Pi)

> **注意:** k3s インストール完了後に実施する。

```bash
mkdir -p ~/.kube
scp ubuntu@192.168.211.21:/etc/rancher/k3s/k3s.yaml ~/.kube/config
sed -i 's/127.0.0.1/192.168.211.21/g' ~/.kube/config
```

接続確認:

```bash
kubectl get nodes
```

---

## 4. helm のインストール (Raspberry Pi)

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

---

## 次のステップ

k3s クラスターが構成できたら Prometheus + Grafana をデプロイする。

```bash
cd ~/proxmox-lab/k8s/monitoring
bash install.sh
```

→ 詳細は [monitoring/README.md](monitoring/README.md) を参照。
