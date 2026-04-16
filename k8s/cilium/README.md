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

`terraform/main.tf` の k3s-master / worker の `k3s_install_args` に以下を追加して `terraform apply`:

```hcl
# k3s-master
"--flannel-backend=none",
"--disable-network-policy",

# worker (server URL に接続するだけなので変更不要)
```

> Terraform apply 時に `remote-exec` で `/etc/systemd/system/k3s.service` が更新され k3s が再起動される。

### 3. 既存 flannel リソースの削除

```bash
# Raspberry Pi 上で実行
kubectl delete daemonset -n kube-system kube-flannel || true
kubectl delete configmap -n kube-system kube-flannel-cfg || true
# flannel の残留 iptables ルールを各ノードでクリア (Ansible で実施)
ansible-playbook -i inventory/hosts.yml playbooks/09-flannel-cleanup.yml
```

### 4. Cilium のインストール

```bash
# ArgoCD Application を apply (automated は無効のまま手動 sync)
kubectl apply -f k8s/argocd/apps/cilium.yaml
kubectl -n argocd app sync cilium
```

### 5. 動作確認

```bash
cilium status
cilium connectivity test
kubectl get nodes  # Ready になっていることを確認
```

### 6. argocd/apps/cilium.yaml の automated sync を有効化

`cilium.yaml` の `syncPolicy.automated` のコメントアウトを外して commit & push。

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
