# Cilium + Hubble ガイド

## 概要

Cilium は eBPF ベースの Kubernetes CNI (Container Network Interface)。
既存の flannel を置き換えることで、L7 ポリシー (HTTP/gRPC レベル) の制御とネットワーク可観測性 (Hubble) が利用可能になる。

### flannel との比較

| 機能 | flannel | Cilium |
|------|---------|--------|
| L3/L4 ポリシー | 基本のみ | 高機能 |
| L7 ポリシー (HTTP/gRPC) | 不可 | 可能 |
| ネットワーク可観測性 | なし | Hubble UI でフロー可視化 |
| kube-proxy 置き換え | 不可 | 可能 (kubeProxyReplacement) |
| eBPF | 不使用 | フル活用 |
| Prometheus メトリクス | なし | 豊富なメトリクス |

---

## Hubble (可観測性)

Hubble は Cilium に組み込まれたネットワーク可観測性ツール。

- **Hubble UI**: ネットワークフローをサービスマップとして可視化
- **Hubble Relay**: 複数ノードのフローを集約
- **Prometheus メトリクス**: HTTP レイテンシー・ドロップ・DNS 等

### Hubble UI でできること

- Pod 間の通信フローをリアルタイム可視化
- ドロップされたパケットの原因特定
- DNS クエリの追跡
- HTTP リクエスト / レスポンスコードの監視

---

## NetworkPolicy (L7)

Cilium では標準の Kubernetes NetworkPolicy に加えて `CiliumNetworkPolicy` が使える。

```yaml
# HTTP パスレベルでのアクセス制御
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-get-only
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
                path: "/api/v1/.*"
```

---

## Hubble CLI

```bash
# インストール (Raspberry Pi)
HUBBLE_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/hubble/master/stable.txt)
curl -L --remote-name-all https://github.com/cilium/hubble/releases/download/$HUBBLE_VERSION/hubble-linux-amd64.tar.gz
tar xzvf hubble-linux-amd64.tar.gz
sudo mv hubble /usr/local/bin/

# フローの確認
hubble observe --namespace default
hubble observe --type drop
hubble observe --protocol http

# ポートフォワード (リモートから Hubble Relay に接続)
kubectl port-forward -n kube-system svc/hubble-relay 4245:80
```

---

## Cilium CLI

```bash
# クラスターの状態確認
cilium status

# 接続性テスト
cilium connectivity test

# エンドポイント一覧
cilium endpoint list
```
