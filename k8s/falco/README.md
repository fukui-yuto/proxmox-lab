# Falco

syscall レベルのランタイム脅威検知。コンテナ内の不審な動作を検知して Alertmanager に転送する。

## 構成

| 項目 | 値 |
|------|-----|
| Helm chart | falcosecurity/falco 4.11.0 |
| Namespace | falco |
| ArgoCD Sync Wave | 4 |
| ドライバー | modern_ebpf (カーネルヘッダー不要) |
| Falcosidekick UI | http://falco.homelab.local |

## ファイル構成

```
k8s/falco/
├── values.yaml      # Helm values
├── README.md        # 本ファイル
└── GUIDE.md         # 概念説明・ルール一覧

k8s/argocd/apps/
└── falco.yaml       # ArgoCD Application
```

## セットアップ

### hosts ファイルへの追記

```powershell
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.24  falco.homelab.local"
```

### ArgoCD への登録

```bash
# Raspberry Pi 上で実行
kubectl apply -f k8s/argocd/apps/falco.yaml
```

## アラート転送先

Falcosidekick → Alertmanager (`kube-prometheus-stack-alertmanager.monitoring:9093`)

priority が `warning` 以上のアラートを転送する。

## 確認

```bash
# リアルタイムログ
kubectl logs -n falco -l app.kubernetes.io/name=falco -f

# Pod 状態
kubectl get pods -n falco
```

## 詳細

ドライバー種別・デフォルトルール・カスタムルール追加方法は [GUIDE.md](./GUIDE.md) を参照。
