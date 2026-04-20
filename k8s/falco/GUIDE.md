# Falco ガイド

## 概要

Falco は syscall レベルでコンテナ・ホストの挙動を監視するランタイム脅威検知ツール。
Kyverno が Admission 時 (デプロイ前) のポリシー違反を検知するのに対し、Falco は **実行時** の異常を検知する補完的な役割を持つ。

### Kyverno との比較

| 機能 | Kyverno | Falco |
|------|---------|-------|
| タイミング | Admission (デプロイ時) | Runtime (実行時) |
| 検知対象 | マニフェスト違反 | syscall 異常 / 不審な動作 |
| 対応 | ブロック / Mutate | アラート送信 |
| eBPF | 不要 | modern_ebpf ドライバー使用 |

---

## ドライバー

| ドライバー | 説明 | 推奨環境 |
|-----------|------|---------|
| `kmod` | カーネルモジュール | 古い環境 |
| `ebpf` | eBPF プログラム | カーネル 4.14+ |
| `modern_ebpf` | CO-RE eBPF (カーネルヘッダー不要) | カーネル 5.8+ (推奨) |

homelab の k3s ノードは Ubuntu 22.04 (カーネル 5.15+) のため `modern_ebpf` を使用。

---

## デフォルトルール (例)

Falco にはデフォルトルールセットが付属している。

| ルール | 説明 |
|--------|------|
| Terminal shell in container | コンテナ内でシェルが起動 |
| Write below binary dir | /bin, /sbin への書き込み |
| Read sensitive file untrusted | /etc/shadow 等への不審なアクセス |
| Outbound connection to C2 servers | 既知の C2 サーバーへの接続 |
| Privilege escalation via su or sudo | 特権昇格の試み |

---

## Falcosidekick によるアラート転送

Falcosidekick は Falco からアラートを受け取り、各種出力先に転送するサイドカー。

```
Falco → Falcosidekick → Alertmanager → aiops-alerting → 通知
```

homelab では Alertmanager に転送することで Grafana アラートと統合する。

---

## カスタムルールの追加

```yaml
# values.yaml に追記
customRules:
  my-rules.yaml: |-
    - rule: Unexpected outbound connection
      desc: Detect unexpected outbound connections
      condition: >
        outbound and not proc.name in (allowed_processes)
      output: >
        Unexpected outbound connection (proc=%proc.name
        src=%fd.sip:%fd.sport dst=%fd.dip:%fd.dport)
      priority: WARNING
```

---

## 確認コマンド

```bash
# Falco Pod のログ (リアルタイム検知)
kubectl logs -n falco -l app.kubernetes.io/name=falco -f

# Falcosidekick UI
# http://falco.homelab.local

# アラート統計
kubectl logs -n falco -l app=falcosidekick | grep -i alert
```

---

## ファイル構成と各ファイルのコード解説

### ファイル構成一覧

| ファイル | パス | 役割 |
|---------|------|------|
| `values.yaml` | `k8s/falco/values.yaml` | Falco Helm chart のカスタム設定値 |
| `README.md` | `k8s/falco/README.md` | セットアップ手順・確認コマンド |
| `GUIDE.md` | `k8s/falco/GUIDE.md` | 概念説明・学習用ドキュメント (本ファイル) |
| `falco.yaml` | `k8s/argocd/apps/falco.yaml` | ArgoCD Application マニフェスト |

---

### values.yaml の全設定解説

`values.yaml` は Falco Helm chart (`falcosecurity/falco`) に渡すカスタム値を定義するファイル。
Helm chart のデフォルト値を上書きし、homelab 環境に最適化している。

---

#### 1. driver セクション — eBPF ドライバーの選択

```yaml
driver:
  kind: modern_ebpf
```

**何をしているか:**
Falco がカーネルの syscall を監視するために使用するドライバーの種類を指定している。

**`modern_ebpf` を選択した理由:**

| 候補 | 結果 | 理由 |
|------|------|------|
| `ebpf` (従来型) | NG | kernel 6.8.0-107 向けのプローブが Falco のダウンロードサーバーに存在しない |
| `kmod` (カーネルモジュール) | NG | kernel 6.4+ で `class_create()` API が変更され、ビルドが失敗する |
| `modern_ebpf` (CO-RE) | OK | BTF (BPF Type Format) 対応。Ubuntu 24.04 は BTF 付きカーネルのため動作する |

**CO-RE (Compile Once - Run Everywhere) とは:**
従来の eBPF ではカーネルバージョンごとにプローブをコンパイルする必要があったが、CO-RE を使うと BTF 情報を利用してカーネルバージョンに依存せず一つのバイナリで動作する。カーネルヘッダーのインストールも不要。

**前提条件:**
- カーネル 5.8 以上 (homelab は 6.8+ なので問題なし)
- `perf_event_paranoid` が 1 以下であること → Terraform の `null_resource.k3s_sysctl_falco` で `/etc/sysctl.d/99-falco.conf` を配置して設定済み

---

#### 2. falco セクション — Falco コアの設定

```yaml
falco:
  grpc:
    enabled: false
  grpc_output:
    enabled: false
  json_output: true
  json_include_output_property: true
```

**各設定の意味:**

| 設定 | 値 | 説明 |
|------|-----|------|
| `grpc.enabled` | `false` | gRPC サーバーを無効化。gRPC の TCP モードでは TLS 証明書が必要になるため無効にしている |
| `grpc_output.enabled` | `false` | gRPC 経由のアラート出力を無効化。Falcosidekick は HTTP 経由でアラートを受信するため gRPC 出力は不要 |
| `json_output` | `true` | アラート出力を JSON 形式にする。構造化データとして Falcosidekick やログ収集基盤で扱いやすくなる |
| `json_include_output_property` | `true` | JSON 出力に `output` フィールド (人間が読みやすい形式のメッセージ) を含める |

**なぜ gRPC を無効にするか:**
Falco の gRPC は Unix ソケットまたは TCP で通信できるが、TCP モードでは相互 TLS (mTLS) が必須。homelab では cert-manager で証明書を自動発行する仕組みはあるが、Falcosidekick が HTTP で十分に機能するため、複雑さを避けて無効化している。

**JSON 出力の例:**
```json
{
  "output": "19:32:45.123 Warning Shell spawned in a container (user=root container=nginx-abc123 shell=bash)",
  "priority": "Warning",
  "rule": "Terminal shell in container",
  "time": "2024-01-01T19:32:45.123456789Z",
  "output_fields": {
    "container.name": "nginx-abc123",
    "user.name": "root",
    "proc.name": "bash"
  }
}
```

---

#### 3. falcosidekick セクション — アラート転送

```yaml
falcosidekick:
  enabled: true
  replicaCount: 1
  config:
    alertmanager:
      hostport: "http://kube-prometheus-stack-alertmanager.monitoring:9093"
      endpoint: "/api/v2/alerts"
      minimumpriority: "warning"
```

**何をしているか:**
Falcosidekick を有効化し、検知したアラートを Alertmanager に転送する設定。

**各設定の意味:**

| 設定 | 値 | 説明 |
|------|-----|------|
| `enabled` | `true` | Falcosidekick を Falco と一緒にデプロイする |
| `replicaCount` | `1` | レプリカ数。homelab ではリソース節約のため 1 |
| `config.alertmanager.hostport` | `http://kube-prometheus-stack-alertmanager.monitoring:9093` | Alertmanager の k8s 内部 DNS 名とポート |
| `config.alertmanager.endpoint` | `/api/v2/alerts` | Alertmanager v2 API のアラート受信エンドポイント |
| `config.alertmanager.minimumpriority` | `"warning"` | `warning` 以上の優先度のアラートのみ転送。`notice` や `informational` は無視 |

**アラートの流れ:**
```
syscall 発生
  → Falco (eBPF で検知、ルールに照合)
    → Falcosidekick (HTTP でアラート受信)
      → Alertmanager (kube-prometheus-stack, ポート 9093)
        → aiops-alerting (通知・自動対応)
```

**Alertmanager の内部 DNS 名の構造:**
`kube-prometheus-stack-alertmanager.monitoring:9093` は以下のように分解される:
- `kube-prometheus-stack-alertmanager` — Service 名 (Helm リリース名 + コンポーネント名)
- `.monitoring` — Namespace 名
- `:9093` — Alertmanager のデフォルト待受ポート

**優先度レベル (Falco):**

| 優先度 | 転送される? | 例 |
|--------|-----------|-----|
| Emergency | はい | - |
| Alert | はい | - |
| Critical | はい | /etc/shadow への書き込み |
| Error | はい | - |
| Warning | はい | コンテナ内でシェル起動 |
| Notice | いいえ | - |
| Informational | いいえ | - |
| Debug | いいえ | - |

---

#### 4. falcosidekick.webui セクション — Web UI

```yaml
  webui:
    enabled: true
    replicaCount: 1
    ingress:
      enabled: true
      annotations:
        kubernetes.io/ingress.class: traefik
      hosts:
        - host: falco.homelab.local
          paths:
            - path: /
              pathType: Prefix
    resources:
      requests:
        cpu: 20m
        memory: 64Mi
      limits:
        cpu: 200m
        memory: 128Mi
```

**何をしているか:**
Falcosidekick UI (Web ダッシュボード) を有効化し、Traefik Ingress 経由でブラウザからアクセスできるようにする。

**各設定の意味:**

| 設定 | 値 | 説明 |
|------|-----|------|
| `webui.enabled` | `true` | Web UI をデプロイする |
| `webui.replicaCount` | `1` | リソース節約のため 1 Pod |
| `ingress.enabled` | `true` | Ingress リソースを作成する |
| `ingress.annotations` | `kubernetes.io/ingress.class: traefik` | Traefik Ingress Controller を使用 |
| `hosts[0].host` | `falco.homelab.local` | ブラウザでアクセスする FQDN |
| `hosts[0].paths[0].path` | `/` | 全パスを UI にルーティング |
| `hosts[0].paths[0].pathType` | `Prefix` | プレフィックスマッチ |

**リソース設定:**
- `requests` — k8s スケジューラがノード配置時に確保する最低リソース量
- `limits` — Pod が使用できるリソースの上限。超過すると OOMKill される

Web UI はアラートの一覧表示・フィルタリング・統計表示を行う軽量なアプリケーションのため、少ないリソースで十分動作する。

---

#### 5. falcosidekick.resources セクション — Sidekick 本体のリソース

```yaml
  resources:
    requests:
      cpu: 20m
      memory: 64Mi
    limits:
      cpu: 200m
      memory: 128Mi
```

**何をしているか:**
Falcosidekick 本体 (アラート転送コンポーネント) の CPU / メモリリソースを制限する。

**設定値の根拠:**
Falcosidekick はアラートを HTTP POST で転送するだけの軽量プロセスのため、少ないリソースで十分。homelab のワーカーノードは 4-8GB RAM のため、リソースを節約することが重要。

---

#### 6. resources セクション — Falco 本体のリソース

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
Falco 本体 (DaemonSet として各ノードで動作) の CPU / メモリリソースを制限する。

**なぜ Sidekick より多いか:**
Falco 本体は eBPF プログラムを通じて全ての syscall をリアルタイムで解析するため、Sidekick (単なる HTTP 転送) よりも多くのリソースを必要とする。

| コンポーネント | CPU requests | Memory requests | 理由 |
|--------------|-------------|----------------|------|
| Falco 本体 | 100m | 256Mi | syscall 解析 + ルール評価 |
| Falcosidekick | 20m | 64Mi | HTTP POST 転送のみ |
| Falcosidekick UI | 20m | 64Mi | Web サーバー + Redis |

**CPU の単位:**
- `100m` = 0.1 vCPU (100 ミリコア)
- `1000m` = 1 vCPU (1 コア分)

---

#### 7. tolerations セクション — マスターノードへのスケジューリング

```yaml
tolerations:
  - effect: NoSchedule
    key: node-role.kubernetes.io/master
    operator: Exists
```

**何をしているか:**
k3s マスターノード (`k3s-master`, 192.168.210.21) には `NoSchedule` taint が設定されており、通常のワークロードはスケジュールされない。この toleration を追加することで、Falco Pod がマスターノード上でも動作できるようにする。

**なぜ必要か:**
Falco は DaemonSet として全ノードで動作し、そのノード上の全 syscall を監視する。マスターノードを監視対象から外すと、コントロールプレーンへの攻撃を検知できなくなるため、toleration を追加してマスターノードにもデプロイする。

**Taint と Toleration の仕組み:**
```
ノード側 (Taint):     node-role.kubernetes.io/master:NoSchedule
  → 「このノードには通常の Pod をスケジュールしないで」

Pod 側 (Toleration):  key=node-role.kubernetes.io/master, effect=NoSchedule
  → 「この taint があっても自分はスケジュールしてよい」
```

**`operator: Exists` の意味:**
taint の値 (value) を問わず、キーが存在すれば toleration が適用される。値を指定する `Equal` と比べて柔軟。

---

#### 8. collectors セクション — コンテナメタデータの収集

```yaml
collectors:
  enabled: true
  docker:
    enabled: false
  containerd:
    enabled: true
    socket: /run/containerd/containerd.sock
```

**何をしているか:**
Falco がコンテナのメタデータ (コンテナ名、イメージ名、Pod 名など) を取得するためのコレクター設定。

**各設定の意味:**

| 設定 | 値 | 説明 |
|------|-----|------|
| `collectors.enabled` | `true` | メタデータ収集を有効化 |
| `docker.enabled` | `false` | Docker ソケットからの収集を無効化 (k3s は Docker を使わない) |
| `containerd.enabled` | `true` | containerd ソケットからの収集を有効化 |
| `containerd.socket` | `/run/containerd/containerd.sock` | containerd の Unix ソケットパス |

**なぜ containerd か:**
k3s はコンテナランタイムとして containerd を使用する (Docker ではない)。Falco がアラートを出す際に「どのコンテナで発生したか」を表示するために、containerd のソケットに接続してメタデータを取得する必要がある。

**ソケットパスについて:**
`/run/containerd/containerd.sock` は k3s 環境でのデフォルトパス。Falco Pod はこのパスをホストからボリュームマウントして読み取る。

**メタデータなしの場合のアラート例:**
```
Shell spawned (user=root proc=bash container=<NA>)
```

**メタデータありの場合のアラート例:**
```
Shell spawned (user=root proc=bash container=nginx-deployment-abc123 namespace=default pod=nginx-deployment-7d4f8b-xyz)
```

コレクターが有効でないと、どの Pod / コンテナで問題が起きたかを特定できないため、運用上必須の設定。

---

#### 9. ArgoCD Application マニフェスト (`k8s/argocd/apps/falco.yaml`)

このファイルは `values.yaml` とは別だが、Falco のデプロイに不可欠なため解説する。

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: falco
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "4"
```

**Sync Wave "4" の意味:**
ArgoCD の Sync Wave は数値が小さいものから順にデプロイされる。Falco は Wave 4 で、Kyverno (Wave 0-1) や Longhorn (Wave 2)、Vault (Wave 3) が起動した後にデプロイされる。

```yaml
spec:
  sources:
    - repoURL: https://falcosecurity.github.io/charts
      chart: falco
      targetRevision: "5.0.0"
      helm:
        valueFiles:
          - $values/k8s/falco/values.yaml
    - repoURL: https://github.com/fukui-yuto/proxmox-lab
      targetRevision: HEAD
      ref: values
```

**Multi-source 構成:**
- 1つ目のソース: Falco 公式 Helm chart リポジトリから chart バージョン `5.0.0` を取得
- 2つ目のソース: 自分の Git リポジトリから `values.yaml` を取得 (`$values` で参照)

この構成により、chart は公式から取得しつつ、設定値は Git 管理できる。

```yaml
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

| 設定 | 説明 |
|------|------|
| `automated` | Git に変更が push されると自動で Sync する |
| `prune: true` | Git から削除されたリソースは k8s からも削除する |
| `selfHeal: true` | 手動変更があっても Git の状態に自動修復する |
| `CreateNamespace=true` | `falco` namespace が存在しなければ自動作成 |
| `ServerSideApply=true` | Server-Side Apply を使用 (大きなリソースのフィールド競合を防止) |

```yaml
  ignoreDifferences:
    - group: apps
      kind: StatefulSet
      name: falco-falcosidekick-ui-redis
      jsonPointers:
        - /spec/volumeClaimTemplates
```

**ignoreDifferences の意味:**
Falcosidekick UI は内部で Redis (StatefulSet) を使用するが、`volumeClaimTemplates` は一度作成されると k8s API が自動的にデフォルト値を追加する。これが ArgoCD から見ると「ドリフト」として検出されるため、この差分を無視するよう設定している。
