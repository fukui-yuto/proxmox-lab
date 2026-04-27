# Traefik 詳細ガイド — リバースプロキシ / Ingress Controller

## このツールが解決する問題

Kubernetes 内のアプリ (Pod) はクラスター内部の IP しか持たない。
外部のブラウザから `http://grafana.homelab.local` にアクセスしても、
そのままでは Pod に到達できない。

| 問題 | 内容 |
|------|------|
| 外部アクセス不可 | Pod はクラスター内部 IP しかない |
| ポート管理 | アプリごとにポート番号を覚えるのは非現実的 |
| ルーティング | `grafana.homelab.local` と `argocd.homelab.local` を同じ IP で振り分けたい |
| TLS 終端 | HTTPS の証明書を各アプリで個別に管理したくない |

Traefik は「Ingress Controller」として、**外部からのHTTPリクエストを正しいPodに振り分ける**。

---

## Ingress Controller とは

```
                        ┌── grafana.homelab.local → Grafana Pod
ブラウザ → Traefik ─────┼── argocd.homelab.local  → ArgoCD Pod
  (HTTP)   (振り分け)    ├── harbor.homelab.local  → Harbor Pod
                        └── kibana.homelab.local  → Kibana Pod
```

Nginx でリバースプロキシを建てるのと同じ考え方だが、
Kubernetes の `Ingress` リソースを読み取って**自動でルーティング設定を更新**してくれる。
新しい Ingress を作るだけで、Traefik の設定を手動で触る必要がない。

---

## k3s と Traefik の関係

k3s には Traefik が**組み込み (built-in)** で入っている。
通常の Kubernetes では自分で Ingress Controller をインストールする必要があるが、
k3s はデフォルトで Traefik をデプロイしてくれる。

```
k3s インストール
  → 自動で Traefik Helm chart がデプロイされる
  → kube-system namespace に traefik Pod が起動
  → Ingress リソースを作れば自動でルーティング開始
```

設定をカスタマイズするには `HelmChartConfig` リソースを使う。

---

## ファイル構成と解説

### `helmchartconfig.yaml` — k3s 組み込み Traefik の設定オーバーライド

```yaml
apiVersion: helm.cattle.io/v1    # k3s 独自の API (Rancher/k3s が提供)
kind: HelmChartConfig            # k3s 組み込み Helm chart の設定を上書きするリソース
metadata:
  name: traefik                  # 上書き対象の chart 名 (k3s が管理する traefik)
  namespace: kube-system         # k3s の組み込み chart は kube-system に配置される
spec:
  valuesContent: |-              # Helm values を YAML 文字列として埋め込む
    service:
      spec:
        externalIPs:             # ← Service に外部 IP を直接割り当てる
          - 192.168.210.21       # k3s-master
          - 192.168.210.24       # k3s-worker03
          - 192.168.210.25       # k3s-worker04
          - 192.168.210.26       # k3s-worker05
          - 192.168.210.27       # k3s-worker06
          - 192.168.210.28       # k3s-worker07
          - 192.168.210.30       # k3s-worker09
          - 192.168.210.31       # k3s-worker10
          - 192.168.210.32       # k3s-worker11
```

**このファイルの目的:**

1. k3s にはデフォルトで `servicelb` (klipper-lb) というロードバランサーがあった
2. Cilium CNI に移行した際に `servicelb` を無効化した
3. `servicelb` がないと Traefik Service の `status.loadBalancer.ingress` が空になる
4. 代わりに `externalIPs` で各ノードの IP を明示的に指定
5. Cilium の BPF が `externalIPs` を直接処理し、どのノード IP でもアクセス可能にする

---

## HelmChartConfig とは

k3s 独自のリソースで、k3s が自動デプロイする Helm chart (traefik, coredns等) の
values を上書きするために使う。

```
通常の Helm:
  helm install traefik --values my-values.yaml

k3s 組み込み chart:
  HelmChartConfig リソースを apply → k3s が自動で values をマージして再デプロイ
```

---

## 外部からのアクセスの流れ

```
1. ブラウザが http://grafana.homelab.local にアクセス
      ↓
2. DNS (Pi-hole) が grafana.homelab.local → 192.168.210.25 に解決
      ↓
3. パケットが k3s-worker04 (192.168.210.25) に到達
      ↓
4. Cilium BPF が externalIP 宛のパケットを Traefik Pod に転送
      ↓
5. Traefik が Host ヘッダー (grafana.homelab.local) を見て
   Ingress ルールに従い Grafana Service にルーティング
      ↓
6. Grafana Pod がレスポンスを返す
```

---

## Ingress リソースの書き方 (おさらい)

各アプリが自分の Ingress を宣言すれば、Traefik が自動で拾う:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: grafana
  namespace: monitoring
spec:
  ingressClassName: traefik        # ← Traefik に処理してもらう
  rules:
    - host: grafana.homelab.local  # ← このドメインへのアクセスを...
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: monitoring-grafana  # ← この Service に転送
                port:
                  number: 80
```

---

## externalIPs vs LoadBalancer vs NodePort

| 方式 | 仕組み | このラボでの利用 |
|------|--------|----------------|
| **externalIPs** | Service に静的 IP を割り当て | 現在使用中 (Cilium BPF で処理) |
| **LoadBalancer** | クラウドの LB や MetalLB が IP を払い出す | servicelb 無効化前に使用していた |
| **NodePort** | 全ノードの特定ポート (30000-32767) で公開 | ポート番号が使いにくいので不採用 |

---

## よくある疑問

### Q: なぜ Nginx Ingress Controller ではなく Traefik？

k3s にデフォルトで組み込まれているから。追加インストール不要で動く。
機能的にはどちらでもほぼ同じことができる。

### Q: Traefik と Cilium の役割の違いは？

| レイヤー | 担当 | 役割 |
|---------|------|------|
| L7 (HTTP) | Traefik | ドメイン名・パスによるルーティング |
| L3/L4 (IP/TCP) | Cilium | パケットの転送・フィルタリング・externalIP の処理 |

### Q: Ingress を作ったのにアクセスできない場合は？

1. DNS が正しい IP を返しているか確認 (`nslookup`)
2. `ingressClassName: traefik` が指定されているか
3. backend の Service 名・ポートが正しいか
4. Traefik Pod が動いているか (`kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik`)
