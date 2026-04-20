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

---

## ファイル構成と各ファイルのコード解説

### ファイル構成一覧

| ファイルパス | 役割 | 説明 |
|---|---|---|
| `k8s/cilium/values.yaml` | Helm values ファイル | Cilium Helm chart に渡すカスタム設定値。クラスター固有のネットワーク設定、Hubble の有効化、リソース制限などを定義する |
| `k8s/cilium/README.md` | 運用手順書 | 移行手順、トラブルシューティング、設定変更時の手順などを記載 |
| `k8s/cilium/GUIDE.md` | 概念説明・学習ドキュメント | Cilium/Hubble の概念、NetworkPolicy の書き方、CLI の使い方（本ファイル） |
| `k8s/argocd/apps/cilium.yaml` | ArgoCD Application マニフェスト | ArgoCD が Cilium Helm chart をどのようにデプロイするかを定義。Sync Wave 0 で最優先起動される |

### ArgoCD Application (`k8s/argocd/apps/cilium.yaml`) の概要

ArgoCD が Cilium を管理するための定義ファイル。以下の構成で動作する:

- **Helm chart ソース**: `helm.cilium.io` リポジトリの `cilium` chart バージョン `1.16.4`
- **values ソース**: GitHub リポジトリ (`proxmox-lab`) の `k8s/cilium/values.yaml` を参照
- **デプロイ先**: `kube-system` namespace（CNI は kube-system で動作する慣例）
- **Sync Wave**: `0`（CNI はクラスターの基盤なので最初に起動する必要がある）
- **自動同期**: `automated.prune: true` + `selfHeal: true` で Git の変更が自動反映される
- **ServerSideApply**: CRD が大きいため Server-Side Apply を使用

---

### values.yaml の全設定解説

`k8s/cilium/values.yaml` は Cilium Helm chart に渡すカスタム設定ファイル。以下、各セクションを詳細に解説する。

---

#### 1. k8sServiceHost / k8sServicePort — Kubernetes API サーバーへの接続先

```yaml
k8sServiceHost: "192.168.210.21"  # k3s-master IP
k8sServicePort: "6443"
```

**何をしているか:**

Cilium エージェントが Kubernetes API サーバーと通信するためのエンドポイントを指定する。

**なぜ必要か:**

通常の Kubernetes クラスターでは、Pod 内から `kubernetes.default.svc` (ClusterIP) 経由で API サーバーに到達できる。しかし Cilium は CNI そのものであり、Pod ネットワークが完全に初期化される前に動作を開始する必要がある。ClusterIP はまだ使えない可能性があるため、API サーバーの実 IP アドレスを直接指定する。

**初心者向けポイント:**
- `192.168.210.21` は k3s-master ノードの IP アドレス
- `6443` は Kubernetes API サーバーのデフォルトポート
- この設定がないと Cilium が起動時に API サーバーを見つけられずクラッシュする

---

#### 2. kubeProxyReplacement — kube-proxy 置き換えモード

```yaml
kubeProxyReplacement: false
```

**何をしているか:**

Cilium が kube-proxy の機能（ClusterIP/NodePort/LoadBalancer の DNAT 処理）を eBPF で置き換えるかどうかを制御する。`false` は「置き換えない」という意味。

**なぜ `false` にしているか（非常に重要）:**

このホームラボ環境では `true` にすると**クラスター全体が通信不能**になる。理由:

1. Cilium は tunnel (VXLAN) モードで動作している
2. `kubeProxyReplacement: true` では、ClusterIP の DNAT（宛先アドレス変換）を **socketLB** という eBPF プログラムが担当する
3. socketLB は Pod の **cgroup** に BPF プログラムをアタッチして動作する
4. しかし k3s の containerd 環境では、Cilium コンテナの cgroup namespace がホストと分離されている
5. その結果、socketLB が Pod の cgroup にアタッチできず、ClusterIP 宛トラフィックが全て `non-routable` としてドロップされる
6. DNS (10.43.0.10) も ClusterIP なので名前解決が不可能になり、全サービス間通信が全断する

**代わりにどうしているか:**

k3s は `--disable-kube-proxy` なしで起動されているため、k3s 内蔵の kube-proxy が iptables ルールで ClusterIP/NodePort のルーティングを処理する。Cilium は純粋に CNI（Pod 間のネットワーキングと VXLAN トンネル）のみを担当する。

**初心者向けポイント:**
- kube-proxy = Kubernetes の「ロードバランサー」的な役割。Service の仮想 IP を実際の Pod IP に変換する
- 本来 Cilium はこの機能も eBPF で高速に処理できるが、環境の制約で使えない
- **絶対に `true` に変更しないこと** — 変更すると即座にクラスター全断する

---

#### 3. ipam.mode — IP アドレス管理モード

```yaml
ipam:
  mode: "kubernetes"
```

**何をしているか:**

Pod に IP アドレスを割り当てる方式を指定する。`kubernetes` モードでは、Kubernetes が各ノードに割り当てた `node.spec.podCIDR` をそのまま使用する。

**なぜ `kubernetes` モードか:**

もう一つの選択肢 `cluster-pool` モードでは、Cilium が独自の CIDR（IP アドレス範囲）をノードに割り当てる。しかし:

1. 旧 flannel 時代に Kubernetes が各ノードに `podCIDR` を割り当てている
2. kubelet は自ノードの `podCIDR` に基づいてローカル Pod へのルートを管理する
3. `cluster-pool` で Cilium が別の CIDR を使うと、kubelet が知っている CIDR と実際の Pod IP が不一致になる
4. ローカル（同じノード上）の Pod へのトラフィックまで VXLAN 経由になってしまう
5. kubelet のヘルスプローブ（Liveness/Readiness）がタイムアウトし、Pod が CrashLoop する

**初心者向けポイント:**
- IPAM = IP Address Management（IP アドレスの割り当て管理）
- `podCIDR` = 各ノードに割り当てられた Pod 用の IP アドレス範囲（例: 10.42.0.0/24）
- `kubernetes` モードが最もシンプルで安全。Kubernetes 側の既存設定と衝突しない

---

#### 4. hubble — ネットワーク可観測性

```yaml
hubble:
  enabled: true
  relay:
    enabled: true
  ui:
    enabled: true
    ingress:
      enabled: true
      annotations:
        kubernetes.io/ingress.class: traefik
      hosts:
        - hubble.homelab.local
      paths:
        - /
  metrics:
    enabled:
      - dns
      - drop
      - tcp
      - flow
      - port-distribution
      - icmp
      - httpV2:exemplars=true;labelsContext=source_ip,source_namespace,source_workload,destination_ip,destination_namespace,destination_workload,traffic_direction
    serviceMonitor:
      enabled: true
```

**何をしているか:**

Hubble はCilium に組み込まれたネットワーク可観測性プラットフォーム。このセクションで各コンポーネントを有効化している。

**各サブ設定の解説:**

| 設定 | 説明 |
|------|------|
| `hubble.enabled: true` | Hubble 本体を有効化。各ノードの Cilium エージェントがネットワークフローを収集する |
| `relay.enabled: true` | Hubble Relay を有効化。複数ノードのフローデータを集約し、単一のエンドポイントで提供する |
| `ui.enabled: true` | Hubble UI (Web インターフェース) を有効化。ブラウザでサービスマップやフローを可視化できる |
| `ui.ingress` | Traefik Ingress 経由で `http://hubble.homelab.local` からアクセス可能にする |
| `metrics.enabled` | Prometheus メトリクスとして公開するフローの種類を指定する |
| `metrics.serviceMonitor.enabled: true` | kube-prometheus-stack の ServiceMonitor CRD を作成し、Prometheus が自動的にメトリクスを収集する |

**メトリクスの種類:**

| メトリクス | 収集する情報 |
|-----------|-------------|
| `dns` | DNS クエリ/レスポンスの統計（名前解決の成功率、レイテンシー） |
| `drop` | ドロップされたパケットの統計（ポリシー違反、ルーティング不能など） |
| `tcp` | TCP 接続の統計（接続数、リセット数、RTT） |
| `flow` | 全フロー（通信）の基本統計 |
| `port-distribution` | 宛先ポートの分布（どのポートへの通信が多いか） |
| `icmp` | ICMP (ping) トラフィックの統計 |
| `httpV2` | HTTP リクエスト/レスポンスのメトリクス（レイテンシー、ステータスコード）。`exemplars=true` で Grafana Exemplar と連携可能。`labelsContext` で送信元/送信先のメタデータをラベルに含める |

**初心者向けポイント:**
- Hubble UI を使うとクラスター内の通信を「地図」のように見ることができる
- 「なぜ Pod A から Pod B に通信できないのか」を視覚的に調査できる
- ServiceMonitor があると Grafana ダッシュボードでネットワークメトリクスを確認できる

---

#### 5. prometheus — Cilium エージェント自体のメトリクス

```yaml
prometheus:
  enabled: true
  serviceMonitor:
    enabled: true
    trustCRDsExist: true
```

**何をしているか:**

Cilium エージェント（DaemonSet として各ノードで動作）自体の内部メトリクスを Prometheus に公開する。

**Hubble metrics との違い:**

| 項目 | `hubble.metrics` | `prometheus` |
|------|-----------------|--------------|
| 対象 | ネットワークフロー（Pod 間通信） | Cilium エージェント自体の動作 |
| メトリクス例 | HTTP レイテンシー、DNS 成功率 | BPF マップ使用率、エンドポイント数、API リクエスト処理時間 |
| 用途 | アプリケーションのネットワーク監視 | Cilium 自体の健全性監視 |

**`trustCRDsExist: true` の意味:**

Helm chart がインストール時に ServiceMonitor CRD が存在するかチェックする処理をスキップする。このホームラボでは kube-prometheus-stack が先にインストールされているため CRD は確実に存在するが、ArgoCD の sync 順序によってはチェックが失敗する場合があるため `true` にしている。

---

#### 6. operator — Cilium Operator の設定

```yaml
operator:
  prometheus:
    enabled: true
    serviceMonitor:
      enabled: true
      trustCRDsExist: true
  replicas: 1
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 256Mi
```

**何をしているか:**

Cilium Operator は Cilium エージェントとは別にクラスター全体を管理するコンポーネント。CiliumIdentity の GC（ガベージコレクション）、IPAM の管理などを行う。

**各設定の解説:**

| 設定 | 説明 |
|------|------|
| `prometheus.enabled: true` | Operator 自体のメトリクスを Prometheus に公開 |
| `replicas: 1` | Operator のレプリカ数。ホームラボでは 1 で十分（本番環境では HA のため 2） |
| `resources.requests` | Kubernetes スケジューラーがノード選択時に確保するリソース量 |
| `resources.limits` | コンテナが使用できるリソースの上限 |

**リソース設定の考え方:**

- `requests.cpu: 50m` = 0.05 CPU コア（最低保証）
- `requests.memory: 128Mi` = 128 MiB のメモリを最低保証
- `limits.cpu: 500m` = 最大 0.5 CPU コアまで使用可能
- `limits.memory: 256Mi` = 256 MiB を超えるとOOM Kill される

ホームラボはリソースが限られているため、控えめな設定にしている。

---

#### 7. resources — Cilium エージェント (DaemonSet) のリソース制限

```yaml
resources:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 1000m
    memory: 512Mi
```

**何をしているか:**

各ノードで動作する Cilium エージェント Pod のリソース制限を設定する。

**設定値の解説:**

| 設定 | 値 | 意味 |
|------|-----|------|
| `requests.cpu` | 100m | 0.1 CPU コアを最低保証。スケジューラーはこの分のリソースが確保できるノードに配置する |
| `requests.memory` | 256Mi | 256 MiB を最低保証 |
| `limits.cpu` | 1000m | 最大 1 CPU コア。eBPF プログラムのコンパイル時に一時的に高い CPU を使うため余裕を持たせる |
| `limits.memory` | 512Mi | 512 MiB。BPF マップやエンドポイント管理にメモリを使用する |

**初心者向けポイント:**
- Cilium エージェントは DaemonSet なので全ノード（7台）にデプロイされる
- 全ノード合計: requests = 0.7 CPU / 1,792 MiB、limits = 7 CPU / 3,584 MiB
- Operator と異なり、エージェントはノードごとの eBPF データパス処理を担うためやや多めのリソースが必要

---

#### 8. l7Proxy — L7 (アプリケーション層) プロキシ

```yaml
l7Proxy: true
```

**何をしているか:**

CiliumNetworkPolicy で HTTP/gRPC レベルのアクセス制御を使えるようにする。有効にすると Cilium が Envoy ベースのプロキシを Pod のサイドカーとしてトラフィックに挿入できる。

**具体例:**

```yaml
# l7Proxy: true が必要な CiliumNetworkPolicy の例
rules:
  http:
    - method: GET
      path: "/api/v1/users"
```

上記のように「GET /api/v1/users のみ許可」といった HTTP メソッド・パスレベルの制御が可能になる。

**l7Proxy: false にした場合:**
- L3/L4（IP アドレス・ポート番号）レベルのポリシーのみ使用可能
- `toPorts.rules.http` を書いてもエラーになる

**初心者向けポイント:**
- L3 = IP アドレス、L4 = TCP/UDP ポート番号、L7 = HTTP パス・メソッド・ヘッダー
- L7 ポリシーはネットワークの「ファイアウォール」をアプリケーションレベルまで拡張するもの
- 性能オーバーヘッドがあるため、L7 ポリシーを使う通信にのみ適用される（全トラフィックではない）

---

#### 9. bpf.masquerade — BPF マスカレード

```yaml
bpf:
  masquerade: false
```

**何をしているか:**

Pod からクラスター外部へ通信する際の SNAT (Source NAT / マスカレード) を eBPF で行うかどうかを制御する。`false` は「eBPF ではマスカレードしない」という意味。

**なぜ `false` にしているか:**

BPF マスカレードは `kubeProxyReplacement: true` (KPR) が前提の機能。KPR が有効な場合、NodePort BPF プログラムがパケットのソースアドレス変換を行うが、KPR=false ではこのプログラムが無効のため、BPF マスカレードも機能しない。

**代わりにどうしているか:**

k3s 内蔵の kube-proxy が iptables の MASQUERADE ルールで SNAT を処理する。Pod から外部 (例: インターネット) への通信時に、Pod IP をノード IP に変換する処理は iptables が担当する。

**初心者向けポイント:**
- マスカレード = 送信元 IP アドレスを書き換えること
- Pod IP (例: 10.42.1.5) でクラスター外部に通信しても、外部のルーターは Pod IP を知らないので戻りパケットが届かない
- そのためノード IP (例: 192.168.210.25) に書き換えてから外部に送信する
- この処理を eBPF でやるか iptables でやるかの違い。この環境では iptables が担当する

---

#### 10. autoDirectNodeRoutes (コメントアウト) — ノード間ルーティング

```yaml
# ノード間通信: tunnel モードと autoDirectNodeRoutes は共存不可のため tunnel のみ使用
# autoDirectNodeRoutes: true  # native routing モード時のみ有効
```

**何をしているか:**

コメントアウトされている（無効）。この設定は native routing モード時に各ノード間で直接ルートを設定する機能だが、現在の環境では tunnel (VXLAN) モードを使用しているため互換性がなく無効化されている。

**tunnel モード vs native routing モード:**

| モード | 仕組み | 利点 | 制約 |
|--------|--------|------|------|
| tunnel (VXLAN) | ノード間通信を VXLAN でカプセル化 | ネットワーク構成を問わず動作 | オーバーヘッドあり（ヘッダー追加） |
| native routing | ノード間に直接ルートを設定 | オーバーヘッドなし | L2 隣接 or BGP が必要 |

このホームラボでは VXLAN モード（デフォルト）を使用している。flannel 時代も VXLAN だったため、移行の親和性が高い。

**初心者向けポイント:**
- VXLAN = Virtual Extensible LAN。物理ネットワークの上に仮想的なネットワークを作る技術
- Pod 間の通信がノードをまたぐとき、パケットを VXLAN ヘッダーで包んで（カプセル化して）送信する
- 受信側のノードでカプセル化を解除し、宛先 Pod に配送する
