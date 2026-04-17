# LitmusChaos

カオスエンジニアリングフレームワーク。Pod/ノード障害・ネットワーク遅延を意図的に注入して aiops-auto-remediation の動作を検証する。

## 構成

| 項目 | 値 |
|------|-----|
| Helm chart | litmuschaos/litmus 3.28.0 |
| Namespace | litmus |
| ArgoCD Sync Wave | 16 |
| Chaos Center | http://litmus.homelab.local |
| 初期認証 | admin / litmus |
| ストレージ | Longhorn 5Gi (MongoDB 用) |

## ファイル構成

```
k8s/litmus/
├── values.yaml      # Helm values
├── README.md        # 本ファイル
└── GUIDE.md         # 概念説明・実験種別・連携シナリオ

k8s/argocd/apps/
└── litmus.yaml      # ArgoCD Application
```

## セットアップ

### hosts ファイルへの追記

```powershell
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.24  litmus.homelab.local"
```

### ArgoCD への登録

```bash
# Raspberry Pi 上で実行
kubectl apply -f k8s/argocd/apps/litmus.yaml
```

## 使い方 (基本的な Pod 削除テスト)

```bash
kubectl apply -f - <<EOF
apiVersion: litmuschaos.io/v1alpha1
kind: ChaosEngine
metadata:
  name: pod-delete-test
  namespace: default
spec:
  appinfo:
    appns: default
    applabel: "app=my-app"
    appkind: deployment
  engineState: active
  chaosServiceAccount: litmus-admin
  experiments:
    - name: pod-delete
      spec:
        components:
          env:
            - name: TOTAL_CHAOS_DURATION
              value: "30"
            - name: CHAOS_INTERVAL
              value: "10"
            - name: FORCE
              value: "false"
EOF
```

## 実験結果の確認

```bash
kubectl get chaosresult -A
kubectl describe chaosresult pod-delete-test -n default
```

## トラブルシューティング

### Chart 3.28.0 へのアップグレード (2026-04-17 実施)

旧 chart 3.14.0 が依存する `bitnami/mongodb:5.0.8-debian-10-r24` が Docker Hub から削除されたため 3.28.0 にアップグレード。

**変更点:**
- `k8s/argocd/apps/litmus.yaml`: `targetRevision: "3.14.0"` → `"3.28.0"`
- `k8s/litmus/values.yaml`: `mongodb.replicaCount: 1` を明示 (デフォルトが 3 に変わったため)
- chart 3.28.0 が使用する MongoDB イメージ: `bitnamilegacy/mongodb:8.0.13-debian-12-r0`

アップグレード後に既存の MongoDB Pod (`litmus-mongodb-0`, `litmus-mongodb-arbiter-0`) を削除して新イメージで再作成:

```bash
kubectl delete pod litmus-mongodb-0 litmus-mongodb-arbiter-0 -n litmus
```

## 詳細

実験種別・aiops 連携シナリオは [GUIDE.md](./GUIDE.md) を参照。
