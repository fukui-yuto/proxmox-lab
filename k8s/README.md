# k8s — k3s クラスター上へのアプリデプロイ手順

k3s クラスターの構成は `terraform apply` で完結する。
このディレクトリでは k3s クラスター上へのアプリデプロイを管理する。

## 前提条件

- `terraform apply` が完了していること (`kubectl get nodes` で 7 ノード Ready)
- Raspberry Pi に `helm` v3 がインストールされていること

### helm のインストール

```bash
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

## アプリ

| ディレクトリ | アプリ | 用途 | 起動方式 |
|---|---|---|---|
| `argocd/` | ArgoCD | GitOps (全アプリの管理基盤) | 手動デプロイ後に自動管理 |
| `monitoring/` | Prometheus + Grafana | メトリクス監視・可視化 | 常時起動 (automated sync) |
| `logging/` | Elasticsearch + Fluent Bit + Kibana | ログ収集・可視化 | 常時起動 (automated sync) |
| `kyverno/` | Kyverno | ポリシーエンジン | 常時起動 (automated sync) |
| `aiops/` | AIOps (alerting / anomaly-detection / alert-summarizer / auto-remediation) | 予測アラート・ログ異常検知・自動修復 | 常時起動 (automated sync) |
| `vault/` | Vault | シークレット管理 | 常時起動 (automated sync) |
| `harbor/` | Harbor | プライベートコンテナレジストリ | 常時起動 (automated sync) |
| `keycloak/` | Keycloak | SSO / 認証基盤 | 常時起動 (automated sync) |
| `tracing/` | OpenTelemetry + Tempo | 分散トレーシング | 常時起動 (automated sync) |
| `argo-workflows/` | Argo Workflows | 自動修復ワークフローエンジン | 常時起動 (automated sync) |
| `argo-events/` | Argo Events | イベント駆動トリガー (AlertManager → Workflow) | 常時起動 (automated sync) |
| `minio/` | MinIO | S3 互換オブジェクトストレージ (Velero バックアップ先) | 常時起動 (automated sync) |
| `cert-manager/` | cert-manager | TLS 証明書の自動発行・更新 (homelab 内部 CA) | 常時起動 (automated sync) |
| `velero/` | Velero | k8s リソース・PVC の定期バックアップ・DR | 常時起動 (automated sync) |

各ツールの概念・仕組みは各ディレクトリの `GUIDE.md` を参照。

---

## アクセス情報

### Windows hosts ファイルへの追記

> k3s ServiceLB は全ノードで Traefik をリッスンするため、どのワーカー IP でも動作する。
> **pve-node02 の worker IP (192.168.210.24) を使うことで node01 の NIC 負荷を分散できる。**

管理者権限の PowerShell で実行:

```powershell
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.24  minio.homelab.local"
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.24  minio-api.homelab.local"
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.24  grafana.homelab.local"
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.24  kibana.homelab.local"
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.24  elasticsearch.homelab.local"
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.24  argocd.homelab.local"
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.24  harbor.homelab.local"
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.24  keycloak.homelab.local"
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.24  vault.homelab.local"
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.24  argo-workflows.homelab.local"
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.24  alert-summarizer.homelab.local"
```

### URL 一覧

| アプリ | URL | ユーザー | 初期パスワード |
|---|---|---|---|
| MinIO Console | http://minio.homelab.local | `admin` | `Minio12345` |
| Grafana | http://grafana.homelab.local | `admin` | `values.yaml` の `grafana.adminPassword` |
| Kibana | http://kibana.homelab.local | - | - |
| Elasticsearch | http://elasticsearch.homelab.local | - | - |
| ArgoCD | http://argocd.homelab.local | `admin` | `Argocd12345` |
| Harbor | http://harbor.homelab.local | `admin` | `Harbor12345` |
| Keycloak | http://keycloak.homelab.local | `admin` | `Keycloak12345` |
| Vault | http://vault.homelab.local | - | 初期化時の Root Token (要 unseal) |
| Argo Workflows | http://argo-workflows.homelab.local | - | 認証不要 |
| alert-summarizer | http://alert-summarizer.homelab.local | - | - |

> **注意:** 初回ログイン後に各サービスのパスワードを必ず変更すること。
