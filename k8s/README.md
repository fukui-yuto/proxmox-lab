# k8s — k3s クラスター上へのアプリデプロイ手順

k3s クラスターの構成は `terraform apply` で完結する。
このディレクトリでは k3s クラスター上へのアプリデプロイを管理する。

## 前提条件

- `terraform apply` が完了していること (`kubectl get nodes` で 4 ノード Ready)
- Raspberry Pi に `helm` v3 がインストールされていること

### helm のインストール

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

---

## デプロイ済みアプリ

| ディレクトリ | アプリ | 手順 |
|---|---|---|
| `monitoring/` | Prometheus + Grafana | [monitoring/README.md](monitoring/README.md) |

---

## 予定アプリ

| ディレクトリ | アプリ | 用途 |
|---|---|---|
| `logging/` | Elasticsearch + Fluent Bit + Kibana | ログ収集・可視化 |
| `tracing/` | OpenTelemetry + Tempo | 分散トレーシング |
| `argocd/` | ArgoCD | GitOps |
| `harbor/` | Harbor | プライベートコンテナレジストリ |
| `keycloak/` | Keycloak | SSO / 認証基盤 |
| `kyverno/` | Kyverno | ポリシーエンジン |
| `vault/` | Vault | シークレット管理 |
| `cilium/` | Cilium | 高機能 CNI |
