# Cilium — eBPF ベース CNI & ネットワークポリシー

k3s クラスターの CNI を Flannel から Cilium に置き換えて、高度なネットワーク可観測性とポリシーを実現する。

## 重要な注意事項

> **クラスター再構築が必要です**
>
> Cilium は k3s のデフォルト CNI (Flannel) を置き換えます。
> 既存のクラスターに後から追加するのではなく、k3s インストール時に
> `--flannel-backend=none` を指定してインストールする必要があります。
>
> **既存のワークロードが存在する場合、このフェーズの適用によりクラスターを再構築することになります。**
> 事前にバックアップ・Helm values の退避を行ってください。

## 構成

```
Cilium Agent (DaemonSet)  ← 各ノードの eBPF ネットワーク処理
Cilium Operator           ← クラスター全体の管理
Hubble Relay              ← フロー可視化プロキシ
Hubble UI                 ← ネットワークフロー可視化 (http://hubble.homelab.local)
```

## 事前準備: k3s の再インストール

### STEP 1: 既存 k3s のアンインストール

全ノードでワークロードを退避後、k3s をアンインストールする。

```bash
# master ノードでのアンインストール
/usr/local/bin/k3s-uninstall.sh

# worker ノードでのアンインストール
/usr/local/bin/k3s-agent-uninstall.sh
```

### STEP 2: k3s master の再インストール (Flannel 無効化)

```bash
# master ノードで実行
curl -sfL https://get.k3s.io | sh -s - \
  --flannel-backend=none \
  --disable-network-policy \
  --cluster-cidr=10.42.0.0/16 \
  --service-cidr=10.43.0.0/16
```

> `--flannel-backend=none`: Flannel を無効化して Cilium に置き換える
> `--disable-network-policy`: k3s 組み込みのネットワークポリシーを無効化

### STEP 3: k3s worker の再インストール

```bash
# worker ノードで実行 (master の token を使用)
K3S_TOKEN=$(sudo cat /var/lib/rancher/k3s/server/node-token)  # master で実行

curl -sfL https://get.k3s.io | K3S_URL=https://192.168.211.21:6443 \
  K3S_TOKEN=${K3S_TOKEN} sh -
```

### STEP 4: kubeconfig の再設定

```bash
# Raspberry Pi (ansible 実行環境) で実行
scp ubuntu@192.168.211.21:/etc/rancher/k3s/k3s.yaml ~/.kube/config
sed -i 's/127.0.0.1/192.168.211.21/g' ~/.kube/config
```

## Cilium のインストール

### STEP 1: Helm リポジトリ追加

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update
```

### STEP 2: Cilium のデプロイ

```bash
cd ~/proxmox-lab/k8s/cilium

helm upgrade --install cilium cilium/cilium \
  --version 1.15.6 \
  --namespace kube-system \
  --values values-cilium.yaml \
  --timeout 10m \
  --wait
```

### STEP 3: デプロイ確認

```bash
# Cilium Pod の確認
kubectl get pods -n kube-system -l app.kubernetes.io/name=cilium

# 全ノードで Cilium が Running になっていれば OK
NAME                READY   STATUS    RESTARTS
cilium-xxxx         1/1     Running   0  (master)
cilium-yyyy         1/1     Running   0  (worker1)
cilium-zzzz         1/1     Running   0  (worker2)
cilium-operator-xxx 1/1     Running   0
```

### STEP 4: Cilium の疎通確認

```bash
# cilium-cli のインストール
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
curl -L --remote-name-all \
  https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz
sudo tar xzvf cilium-linux-amd64.tar.gz -C /usr/local/bin

# ヘルスチェック
cilium status --wait

# 接続テスト (時間がかかる)
cilium connectivity test
```

## Hubble UI へのアクセス

### Ingress 経由でのアクセス

| 項目 | 値 |
|------|-----|
| URL | http://hubble.homelab.local |
| 認証 | なし (ラボ環境) |

#### Windows PC からのアクセス設定

管理者権限の PowerShell で以下を実行する。

```powershell
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.211.21  hubble.homelab.local"
```

### Hubble CLI でのフロー確認

```bash
# hubble-relay へのポートフォワード
kubectl port-forward -n kube-system svc/hubble-relay 4245:80 &

# フローの確認
hubble observe --last 100

# 特定の Namespace のフローを確認
hubble observe --namespace monitoring

# ドロップされたパケットの確認
hubble observe --verdict DROPPED
```

## ネットワークポリシーの例

Cilium では Kubernetes 標準の NetworkPolicy に加え、L7 (HTTP) レベルのポリシーも記述できる。

### 標準 NetworkPolicy の例

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-monitoring
  namespace: monitoring
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              name: monitoring
```

### CiliumNetworkPolicy (L7 HTTP) の例

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-api-get-only
spec:
  endpointSelector:
    matchLabels:
      app: my-api
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: frontend
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
          rules:
            http:
              - method: GET
                path: "/api/.*"
```

## アンインストール

```bash
helm uninstall cilium -n kube-system
```

> **注意:** Cilium をアンインストールすると CNI がなくなり、ネットワーク通信が不能になる。
> アンインストール後は k3s を Flannel 有効の設定で再インストールするか、別の CNI を即座にインストールすること。

## 次のステップ

- Kyverno (Phase 6) と組み合わせてネットワークポリシーを GitOps 管理
- Hubble のメトリクスを Prometheus/Grafana で可視化
- Proxmox SDN (Phase 5-2) と組み合わせてマルチノードのネットワーク分離を実現
