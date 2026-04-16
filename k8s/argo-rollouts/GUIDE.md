# Argo Rollouts ガイド

## 概要

Argo Rollouts は Kubernetes のプログレッシブデリバリー (段階的リリース) コントローラー。
ArgoCD と統合して **カナリアデプロイ** や **Blue-Green デプロイ** を実現する。

### 標準 Deployment との違い

| 機能 | Deployment | Rollout |
|------|-----------|---------|
| デプロイ戦略 | RollingUpdate / Recreate のみ | Canary / Blue-Green |
| トラフィック制御 | 不可 | weight ベースで段階的に移行 |
| 自動昇格 / ロールバック | なし | metrics 判定で自動化可能 |
| ArgoCD 統合 | 標準 | Rollout リソースとして可視化 |

---

## デプロイ戦略

### Canary (カナリア)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: my-app
spec:
  strategy:
    canary:
      steps:
        - setWeight: 10    # 10% のトラフィックを新バージョンへ
        - pause: {}        # 手動承認待ち
        - setWeight: 50
        - pause: {duration: 60s}
        - setWeight: 100
```

### Blue-Green

```yaml
spec:
  strategy:
    blueGreen:
      activeService: my-app-active
      previewService: my-app-preview
      autoPromotionEnabled: false  # 手動昇格
```

---

## Analysis (自動判定)

Prometheus メトリクスで自動ロールバック/昇格を判定できる。

```yaml
spec:
  strategy:
    canary:
      analysis:
        templates:
          - templateName: success-rate
        startingStep: 2
        args:
          - name: service-name
            value: my-app-canary
---
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: success-rate
spec:
  metrics:
    - name: success-rate
      interval: 30s
      failureLimit: 3
      provider:
        prometheus:
          address: http://kube-prometheus-stack-prometheus.monitoring:9090
          query: |
            sum(rate(http_requests_total{job="{{args.service-name}}",status!~"5.."}[2m]))
            /
            sum(rate(http_requests_total{job="{{args.service-name}}"}[2m]))
      successCondition: result[0] >= 0.95
```

---

## kubectl プラグイン

```bash
# インストール
curl -LO https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64
chmod +x kubectl-argo-rollouts-linux-amd64 && mv it /usr/local/bin/kubectl-argo-rollouts

# Rollout 一覧
kubectl argo rollouts list rollouts -n <namespace>

# 状態確認
kubectl argo rollouts get rollout <name> -n <namespace> --watch

# 手動昇格
kubectl argo rollouts promote <name> -n <namespace>

# ロールバック
kubectl argo rollouts undo <name> -n <namespace>
```

---

## ArgoCD との統合

ArgoCD の Application で `Rollout` リソースを管理すると、ArgoCD UI 上で Rollout の進行状況が可視化される。
`argocd-rollouts` namespace の `argo-rollouts-controller` が Rollout リソースを監視し、トラフィック切り替えを制御する。
