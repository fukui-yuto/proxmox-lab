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

| ジョブ名 | 言語 | 内容 |
|---------|------|------|
| hello-world | - | 動作確認用テストジョブ (echo + uname + date) |
| docker-python | Python | Kaniko で Dockerfile をビルドし Python スクリプトを実行 |

### Agent Pod の仕様

| 項目 | 値 |
|------|-----|
| CPU request / limit | 50m / 512m |
| Memory request / limit | 128Mi / 512Mi |
| Pod Retention | Never (ジョブ完了後に自動削除) |

ジョブ実行時のみ Agent Pod が起動し、完了後は自動削除される。常駐するのは Jenkins controller のみ。

## ジョブテンプレート (Cookiecutter)

Cookiecutter テンプレートを使って、新しい Jenkins ジョブを対話式で生成できる。

### 対応言語

| 言語 | ベースイメージ | パッケージ管理 | エントリポイント |
|------|--------------|--------------|----------------|
| Python | `python:3.12-slim` | `pip install` | `app.py` |
| Go | `golang:1.22-alpine` | `go mod` | `main.go` |
| Node.js | `node:22-slim` | `npm install` | `index.js` |
| Shell | `alpine:3.20` | `apk add` | `script.sh` |

### ディレクトリ構成

```
k8s/jenkins/
├── create-job.sh                           # ジョブ生成スクリプト
├── values.yaml                             # Helm values (ジョブ定義を含む)
├── cookiecutter-job-template/              # Cookiecutter テンプレート
│   ├── cookiecutter.json                   #   パラメータ定義
│   ├── register_job.py                     #   values.yaml 更新スクリプト
│   ├── hooks/post_gen_project.py           #   不要ファイル削除フック
│   └── {{cookiecutter.job_name}}/          #   テンプレート本体
│       ├── Jenkinsfile                     #     Kaniko ビルドパイプライン
│       ├── Dockerfile                      #     言語別 Dockerfile (Jinja2)
│       ├── app.py                          #     Python サンプル
│       ├── main.go / go.mod                #     Go サンプル
│       ├── index.js / package.json         #     Node.js サンプル
│       └── script.sh                       #     Shell サンプル
└── jobs/                                   # 生成されたジョブ
    ├── hello-world/
    └── docker-python/
```

### 事前準備

```bash
pip install cookiecutter
```

### ジョブ生成手順

1. スクリプトを実行:

```bash
bash k8s/jenkins/create-job.sh
```

2. 対話式でパラメータを入力:

```
ジョブ名 (英小文字・数字・ハイフン): my-api-test
説明 [テストジョブ]: API テスト
言語を選択:
  1) python
  2) go
  3) node
  4) shell
番号 [1]: 1
追加パッケージ (スペース区切り、不要なら空Enter): requests
```

3. 生成されたファイルを確認し、git push:

```bash
git add k8s/jenkins/jobs/my-api-test/ k8s/jenkins/values.yaml
git commit -m "feat: add my-api-test job (python)"
git push
```

4. ArgoCD sync 後、Jenkins にジョブが自動登録される

### 生成されるファイル (Python 選択時の例)

```
k8s/jenkins/jobs/my-api-test/
├── Jenkinsfile    # Kaniko で Docker イメージをビルド (--no-push)
├── Dockerfile     # python:3.12-slim + pip install requests + python app.py
└── app.py         # サンプルスクリプト
```

### ジョブの実行フロー

1. Jenkins が Agent Pod を起動 (jnlp + kaniko コンテナ)
2. GitHub からリポジトリを checkout
3. Kaniko が Dockerfile をビルド → `RUN` ステップでスクリプトが実行される
4. `--no-push` のためレジストリへの push はしない (ビルド確認のみ)
5. ジョブ完了後、Agent Pod は自動削除される

### 手動でジョブを追加する場合

Cookiecutter を使わず手動で追加する場合:

1. `k8s/jenkins/jobs/<ジョブ名>/Jenkinsfile` を作成
2. `values.yaml` の `JCasC.configScripts.jobs` に Job DSL を追記:
   ```yaml
   - script: >
       pipelineJob('<ジョブ名>') {
         description('<説明>')
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
