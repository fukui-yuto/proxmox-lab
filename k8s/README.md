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

## アプリ

| ディレクトリ | アプリ | 用途 |
|---|---|---|
| `monitoring/` | Prometheus + Grafana | [monitoring/README.md](monitoring/README.md) |
| `logging/` | Elasticsearch + Fluent Bit + Kibana | ログ収集・可視化 |
| `tracing/` | OpenTelemetry + Tempo | 分散トレーシング |
| `argocd/` | ArgoCD | GitOps |
| `harbor/` | Harbor | プライベートコンテナレジストリ |
| `keycloak/` | Keycloak | SSO / 認証基盤 |
| `kyverno/` | Kyverno | ポリシーエンジン |
| `vault/` | Vault | シークレット管理 |

---

## アクセス情報

### Windows hosts ファイルへの追記

管理者権限の PowerShell で実行:

```powershell
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.21  grafana.homelab.local"
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.21  kibana.homelab.local"
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.21  elasticsearch.homelab.local"
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.21  argocd.homelab.local"
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.21  harbor.homelab.local"
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.21  keycloak.homelab.local"
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.21  vault.homelab.local"
```

### URL 一覧

| アプリ | URL | ユーザー | パスワード |
|---|---|---|---|
| Grafana | http://grafana.homelab.local | `admin` | `values.yaml` の `grafana.adminPassword` |
| Kibana | http://kibana.homelab.local | - | - |
| Elasticsearch | http://elasticsearch.homelab.local | - | - |
| ArgoCD | http://argocd.homelab.local | `admin` | `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d` |
| Harbor | http://harbor.homelab.local | `admin` | `Harbor12345` |
| Keycloak | http://keycloak.homelab.local | `admin` | `Keycloak12345` |
| Vault | http://vault.homelab.local | - | 初期化時の Root Token (要 unseal) |
