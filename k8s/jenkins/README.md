# Jenkins

k3s クラスター上で動作する CI/CD サーバー。

## 構成

| 項目 | 値 |
|------|-----|
| Helm Chart | `jenkins/jenkins` (https://charts.jenkins.io) |
| Chart Version | 5.9.18 |
| Namespace | `jenkins` |
| Sync Wave | 16 |
| ストレージ | Longhorn PVC 10Gi |

## アクセス

| 項目 | 値 |
|------|-----|
| URL | http://jenkins.homelab.local |
| admin パスワード | `Jenkins12345` |

### Windows hosts ファイル追記

```powershell
Add-Content -Path "C:\Windows\System32\drivers\etc\hosts" -Value "192.168.210.25  jenkins.homelab.local"
```

## デプロイ

ArgoCD が自動で sync する。手動 sync する場合:

```bash
argocd app sync jenkins
```

## 初期インストール済みプラグイン

- kubernetes (k8s 上での動的エージェント)
- workflow-aggregator (Pipeline)
- git
- configuration-as-code (JCasC)
- job-dsl (JCasC からのジョブ自動生成)

## ジョブ管理 (JCasC + Job DSL)

ジョブは `values.yaml` の `controller.JCasC.configScripts.jobs` で宣言的に管理される。
Jenkins UI での手動作成は不要。

### 登録済みジョブ

| ジョブ名 | Jenkinsfile パス | 内容 |
|---------|-----------------|------|
| hello-world | `k8s/jenkins/jobs/hello-world/Jenkinsfile` | 動作確認用テストジョブ |

### ジョブ追加手順

1. `k8s/jenkins/jobs/<ジョブ名>/Jenkinsfile` を作成
2. `values.yaml` の `JCasC.configScripts.jobs` に Job DSL を追記:
   ```yaml
   - script: >
       pipelineJob('<ジョブ名>') {
         definition {
           cpsScm {
             scm {
               git {
                 remote { url('https://github.com/fukui-yuto/proxmox-lab.git') }
                 branches('*/main')
               }
             }
             scriptPath('k8s/jenkins/jobs/<ジョブ名>/Jenkinsfile')
           }
         }
       }
   ```
3. `git commit && git push` → ArgoCD が自動 sync → ジョブが反映される

## Keycloak SSO 連携 (任意)

初期構築後に OIDC プラグインを追加して Keycloak と連携可能。

1. Jenkins に `oic-auth` プラグインをインストール
2. Keycloak に `jenkins` クライアントを作成
3. Jenkins の Security 設定で OIDC を構成
