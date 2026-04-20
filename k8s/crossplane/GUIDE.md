# Crossplane ガイド

## 概要

Crossplane は Kubernetes CRD を使ってインフラを宣言的に管理するフレームワーク。
Terraform の代替として、Proxmox VM・クラウドリソース・データベース等を `kubectl apply` で管理できるようになる。

### Terraform との比較

| 機能 | Terraform | Crossplane |
|------|-----------|-----------|
| 状態管理 | tfstate ファイル | Kubernetes etcd |
| 差分検出 | `terraform plan` | 継続的な reconciliation |
| ドリフト修正 | 手動 `apply` | 自動 self-heal |
| 宣言方法 | HCL | Kubernetes YAML |
| GitOps 統合 | 要工夫 | ArgoCD とネイティブ統合 |
| 学習コスト | 高 | Kubernetes 知識で対応可 |

---

## 主要コンポーネント

| コンポーネント | 役割 |
|-------------|------|
| Provider | 外部システム (AWS / GCP / Proxmox 等) との接続定義 |
| Managed Resource | Provider が管理する個々のリソース (VM, DB 等) |
| Composite Resource (XR) | 複数 Managed Resource をまとめた抽象化レイヤー |
| Composition | XR の実装 (どの Managed Resource を作るか) |
| Claim | 開発者が使う高レベル API |

---

## Proxmox Provider のセットアップ

```yaml
# Proxmox Provider のインストール
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-proxmox
spec:
  package: xpkg.upbound.io/upbound/provider-proxmox:v0.1.0
---
# 接続情報
apiVersion: v1
kind: Secret
metadata:
  name: proxmox-credentials
  namespace: crossplane-system
type: Opaque
stringData:
  credentials: |
    {
      "username": "terraform@pve",
      "password": "your-password",
      "endpoint": "https://192.168.210.11:8006"
    }
---
apiVersion: proxmox.upbound.io/v1beta1
kind: ProviderConfig
metadata:
  name: default
spec:
  credentials:
    source: Secret
    secretRef:
      namespace: crossplane-system
      name: proxmox-credentials
      key: credentials
```

---

## VM の宣言的管理例

```yaml
apiVersion: proxmox.upbound.io/v1alpha1
kind: VirtualMachine
metadata:
  name: my-vm
spec:
  forProvider:
    node: pve-node03
    vmid: 300
    name: my-vm
    memory: 2048
    cores: 2
    disk:
      - size: 20
        storage: local-zfs
    network:
      - bridge: vmbr0
        model: virtio
  providerConfigRef:
    name: default
```

---

## Composite Resource による抽象化

開発者向けに「k3s ワーカー VM」という抽象リソースを定義する例:

```yaml
apiVersion: apiextensions.crossplane.io/v1
kind: CompositeResourceDefinition
metadata:
  name: xk3sworkers.homelab.io
spec:
  group: homelab.io
  names:
    kind: XK3sWorker
    plural: xk3sworkers
  claimNames:
    kind: K3sWorker
    plural: k3sworkers
  versions:
    - name: v1alpha1
      served: true
      referenceable: true
      schema:
        openAPIV3Schema:
          properties:
            spec:
              properties:
                parameters:
                  properties:
                    memory:
                      type: integer
                    cores:
                      type: integer
                    node:
                      type: string
```

---

## 移行戦略 (Terraform → Crossplane)

現時点では Terraform が稼働中のため、段階的移行を推奨:

1. **新規 VM** のみ Crossplane で管理開始
2. Terraform 既存リソースは `terraform state rm` → Crossplane `import` で移行
3. 全移行完了後に Terraform を廃止

> 現状は Terraform + Raspberry Pi の組み合わせが安定しているため、Crossplane への全面移行は任意。

---

## ファイル構成と各ファイルのコード解説

### ファイル構成一覧

```
k8s/crossplane/
├── values.yaml      # Helm values (Crossplane のカスタム設定)
├── README.md        # セットアップ手順・Provider 設定・確認コマンド
└── GUIDE.md         # 本ファイル (概念説明・Terraform比較・移行戦略)

k8s/argocd/apps/
└── crossplane.yaml  # ArgoCD Application (自動デプロイ定義)
```

---

### values.yaml の詳細解説

Crossplane Helm chart (`crossplane-stable/crossplane`) に渡すカスタム値を定義するファイル。
Crossplane は比較的シンプルな構成で、コントローラ本体と RBAC Manager の 2 コンポーネントで構成される。

#### replicas

```yaml
replicas: 1
```

- **`replicas: 1`**: Crossplane コントローラの Pod 数を 1 に設定。Crossplane コントローラは Leader Election (リーダー選出) に対応しているため複数レプリカでの冗長化が可能だが、homelab ではリソース節約のためシングルレプリカで運用する。
- コントローラが停止しても既存リソースへの影響はない (既に作成された VM 等は動き続ける)。ただし reconciliation (差分修正) が一時停止する。

#### resourcesCrossplane セクション

```yaml
resourcesCrossplane:
  requests:
    cpu: 100m
    memory: 256Mi
  limits:
    cpu: 500m
    memory: 512Mi
```

- **`resourcesCrossplane`**: Crossplane 本体コントローラ Pod に割り当てる CPU / メモリのリソース制限。
- **`requests`**: Pod がスケジュールされる際に保証されるリソース量。Kubernetes スケジューラはこの値を基にどのノードに配置するかを決定する。
- **`limits`**: コンテナが使用できるリソースの上限値。これを超えると CPU はスロットリング、メモリは OOMKill が発生する。
- Crossplane コントローラは CRD の watch + reconcile ループを実行するため、管理するリソース数に応じてメモリ消費が増える。homelab の規模 (数十リソース程度) であれば 512Mi で十分。

#### resourcesRBACManager セクション

```yaml
resourcesRBACManager:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 200m
    memory: 128Mi
```

- **`resourcesRBACManager`**: RBAC Manager コンポーネントに割り当てるリソース。
- **RBAC Manager の役割**: Crossplane の Provider がインストールされると、その Provider が必要とする RBAC (Role-Based Access Control) ルールを自動的に作成・管理するコンポーネント。例えば Proxmox Provider がインストールされると、そのコントローラに必要な ClusterRole / ClusterRoleBinding を自動生成する。
- Crossplane 本体より軽量な処理のため、リソース割り当ても小さくしている (メモリ上限 128Mi)。

#### metrics セクション

```yaml
metrics:
  enabled: true
```

- **`metrics.enabled: true`**: Prometheus 形式のメトリクスエンドポイントを有効化する。
- これにより Crossplane コントローラが `/metrics` エンドポイントで以下の情報を公開する:
  - Managed Resource の reconcile 回数・所要時間
  - Provider の健全性状態
  - CRD の登録状況
- homelab の kube-prometheus-stack (Grafana + Prometheus) がこのメトリクスを自動収集し、Crossplane の動作状況を Grafana ダッシュボードで可視化できる。ServiceMonitor が自動作成されるため、追加設定なしで Prometheus が scrape を開始する。
