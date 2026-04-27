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

### ジョブの自動削除

`values.yaml` の cleanup スクリプトにより、`managedJobs` リストに含まれないジョブは JCasC リロード時に Jenkins から自動削除される。ジョブの追加・削除は `create-job.sh` / `delete-job.sh` が `managedJobs` リストと `pipelineJob()` 定義を自動更新する。

## ジョブテンプレート (Cookiecutter)

Cookiecutter テンプレートを使って、Jenkins ジョブの生成・削除を対話式で行える。

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
├── create-job.sh                           # ジョブ生成スクリプト (対話式)
├── delete-job.sh                           # ジョブ削除スクリプト (対話式)
├── values.yaml                             # Helm values (ジョブ定義を含む)
├── cookiecutter-job-template/              # Cookiecutter テンプレート
│   ├── cookiecutter.json                   #   パラメータ定義
│   ├── register_job.py                     #   values.yaml へジョブ追加
│   ├── unregister_job.py                   #   values.yaml からジョブ削除
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

### ジョブ生成

```bash
bash k8s/jenkins/create-job.sh
```

対話式でパラメータを入力:

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

=== 生成内容 ===
  ジョブ名:   my-api-test
  説明:       API テスト
  言語:       python
  パッケージ: requests
================
作成しますか？ (y/N): y
```

生成後、表示されるコマンドで git push:

```bash
git add k8s/jenkins/jobs/my-api-test/ k8s/jenkins/values.yaml
git commit -m "feat: add my-api-test job (python)"
git push
```

ArgoCD sync 後、Jenkins にジョブが自動登録される。

### ジョブ削除

```bash
bash k8s/jenkins/delete-job.sh
```

対話式で削除するジョブを選択:

```
=== 登録済みジョブ ===
docker-python
hello-world
my-api-test
======================

削除するジョブ名: my-api-test
ジョブ 'my-api-test' を削除しますか？ (y/N): y
```

削除後、表示されるコマンドで git push:

```bash
git add -A k8s/jenkins/jobs/my-api-test/ k8s/jenkins/values.yaml
git commit -m "feat: remove my-api-test job"
git push
```

ArgoCD sync → JCasC リロードで Jenkins からもジョブが自動削除される。

### ジョブの実行フロー

1. Jenkins が Agent Pod を起動 (jnlp + kaniko コンテナ)
2. GitHub からリポジトリを checkout
3. Kaniko が Dockerfile をビルド → `RUN` ステップでスクリプトが実行される
4. `--no-push` のためレジストリへの push はしない (ビルド確認のみ)
5. ジョブ完了後、Agent Pod は自動削除される

### git push → Jenkins 反映の仕組み

```
git push → GitHub → ArgoCD (ポーリング) → Helm 展開 → ConfigMap 更新
→ k8s-sidecar (変更検知) → JCasC リロード → Job DSL 実行 → ジョブ登録/削除
```

## Keycloak SSO 連携 (任意)

初期構築後に OIDC プラグインを追加して Keycloak と連携可能。

1. Jenkins に `oic-auth` プラグインをインストール
2. Keycloak に `jenkins` クライアントを作成
3. Jenkins の Security 設定で OIDC を構成
