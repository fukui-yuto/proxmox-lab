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
