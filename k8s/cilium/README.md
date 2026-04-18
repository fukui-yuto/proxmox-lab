# Cilium + Hubble

eBPF ベース CNI。flannel を置き換えて L7 ポリシー制御と Hubble ネットワーク可観測性を提供する。

## 構成

| 項目 | 値 |
|------|-----|
| Helm chart | cilium/cilium 1.16.4 |
| Namespace | kube-system |
| ArgoCD Sync Wave | 0 (CNI は最優先) |
| Hubble UI | http://hubble.homelab.local |

## ファイル構成

```
k8s/cilium/
├── values.yaml      # Helm values
├── README.md        # 本ファイル
└── GUIDE.md         # 概念説明・NetworkPolicy・CLI

k8s/argocd/apps/
└── cilium.yaml      # ArgoCD Application (automated sync は移行後に有効化)
```

## ✅ 移行ステータス (2026-04-17 完了)

flannel → Cilium の CNI 移行が完了。全 9 ノードで cilium Pod が 1/1 Ready で稼働中。

**移行時に判明したトラブルシューティング事項:**

| 問題 | 原因 | 対処 |
|------|------|------|
| cilium pod CrashLoop (`auto-direct-node-routes cannot be used with tunneling`) | `values.yaml` に `autoDirectNodeRoutes: true` が残存 | `values.yaml` から削除し、`cilium-config` ConfigMap の `auto-direct-node-routes` を `false` に patch |
| `cilium_vxlan: address already in use` | `flannel.1` インターフェースが各ノードに残留し UDP 8472 ポートを占有 | 全ノードで `ip link delete flannel.1` を実行 |
| `init:Error` (`Agent should not be running when cleaning up`) | force delete した Pod の `/var/run/cilium/cilium.pid` が残留 | 各ノードで `sudo rm -f /var/run/cilium/cilium.pid` を実行 |
| ヘルスプローブ HTTP タイムアウト (kubelet → Pod IP) | cilium が `cluster-pool` IPAM で独自 CIDR を割り当てたため、旧 flannel の k8s podCIDR (cni0) と不一致。ローカル Pod へのルートが VXLAN 経由になり kubelet から到達不能 | `ipam.mode: kubernetes` に変更して k8s `node.spec.podCIDR` を使用。master 上の旧 cilium-CIDR Pod は自動的に再起動され新 CIDR IP を取得 |
| 新 Pod が cilium エンドポイントとして登録されず ClusterIP に到達不能 (`dial tcp 10.43.0.1:443: i/o timeout`) | k3s **agent** の kubelet は `/var/lib/rancher/k3s/agent/etc/cni/net.d/` を CNI config dir として使用するが、cilium は `/etc/cni/net.d/` に conflist を書き込む。k3s agent に古い `10-flannel.conflist` が残っていたため kubelet が flannel CNI を引き続き使用し、新 Pod が cni0 ブリッジ接続となって cilium endpoint として登録されなかった | `ansible-playbook playbooks/11-fix-k3s-cni.yml` を実行。各ワーカーの k3s agent CNI dir に `05-cilium.conflist` をコピーし `10-flannel.conflist` を削除。k3s 内蔵 flannel の `net-conf.json` を `"Type": "none"` に更新 |

## ⚠️ CNI 移行手順 (破壊的操作・メンテナンスウィンドウ必須)

> **全 Pod が再起動される。事前にバックアップ (Velero) を取得すること。**

### 1. Velero でバックアップ取得

```bash
kubectl apply -f - <<EOF
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: pre-cilium-migration
  namespace: velero
spec:
  includedNamespaces: ["*"]
EOF
kubectl wait backup/pre-cilium-migration -n velero --for=condition=Completed --timeout=10m
```

### 2. k3s を flannel 無効化で再設定 (Terraform)

`terraform/main.tf` に `null_resource.k3s_disable_flannel` を追加して `terraform apply`:

```hcl
resource "null_resource" "k3s_disable_flannel" {
  triggers = { flannel_disable_version = "1" }
  depends_on = [null_resource.k3s_master_install]
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command = <<-EOT
      ssh ubuntu@192.168.210.21 \
        "sudo mkdir -p /etc/rancher/k3s/config.yaml.d && \
         printf 'flannel-backend: none\ndisable-network-policy: true\n' | \
         sudo tee /etc/rancher/k3s/config.yaml.d/00-cilium.yaml && \
         sudo systemctl restart k3s"
    EOT
  }
}
```

### 3. 既存 flannel リソースの削除

> **重要:** `flannel.1` インターフェースが残ると Cilium が UDP 8472 ポートの競合で起動できない。

```bash
# Raspberry Pi 上で実行
ansible-playbook -i inventory/hosts.yml playbooks/09-flannel-cleanup.yml
```

`09-flannel-cleanup.yml` は以下を実行する:
- kube-flannel DaemonSet / ConfigMap を削除 (存在する場合)
- 各ノードで `ip link delete flannel.1` を実行 ← **Cilium 起動の前提条件**
- 古い `/var/run/cilium/cilium.pid` を削除

### 4. Cilium のインストール

```bash
# ArgoCD Application を apply (automated sync は既に有効化済み)
kubectl apply -f k8s/argocd/apps/cilium.yaml
kubectl -n argocd app sync cilium
```

### 5. 動作確認

```bash
kubectl get pods -n kube-system -l k8s-app=cilium  # 全ノード 1/1 Ready を確認
kubectl get nodes  # 全ノード Ready を確認
```

### 6. argocd/apps/cilium.yaml の automated sync (移行完了後は不要)

`cilium.yaml` の `syncPolicy.automated` は移行時に有効化済み。追加作業不要。

## セットアップ後

### hosts ファイルへの追記

```powershell
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.24  hubble.homelab.local"
```

## 確認

```bash
cilium status
kubectl get pods -n kube-system -l k8s-app=cilium
```

## 詳細

L7 ポリシー・Hubble UI・CLI の使い方は [GUIDE.md](./GUIDE.md) を参照。
