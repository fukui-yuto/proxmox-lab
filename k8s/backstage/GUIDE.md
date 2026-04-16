# Backstage ガイド

## 概要

Backstage は Spotify が開発したオープンソースの開発者ポータル。
全サービスのドキュメント・CI/CD・ログ・依存関係へのワンストップアクセスを提供する「ソフトウェアカタログ」を構築できる。

---

## 主要機能

| 機能 | 説明 |
|------|------|
| Software Catalog | 全サービス・API・インフラの一覧と依存関係可視化 |
| TechDocs | コードと同居する Markdown ドキュメントの自動ホスティング |
| Kubernetes Plugin | クラスター内の Pod・Deployment 状態をサービス単位で表示 |
| ArgoCD Plugin | ArgoCD の Application 状態を Backstage から閲覧 |
| Scaffolder | テンプレートからサービス・リポジトリを自動生成 |

---

## カタログ登録 (catalog-info.yaml)

各サービスのリポジトリルートに `catalog-info.yaml` を置くことでカタログに登録される。

```yaml
apiVersion: backstage.io/v1alpha1
kind: Component
metadata:
  name: my-service
  description: My homelab service
  annotations:
    argocd/app-name: my-service
    backstage.io/kubernetes-id: my-service
    backstage.io/techdocs-ref: dir:.
  tags:
    - go
    - api
spec:
  type: service
  lifecycle: production
  owner: user:fukui-yuto
  system: homelab
  providesApis:
    - my-service-api
```

---

## homelab での活用シナリオ

1. **全サービスの一覧化**: ArgoCD に登録済みの各アプリを Backstage カタログに登録
2. **Kubernetes 状態の統合**: Pod の状態を Backstage の Component ページで確認
3. **ドキュメント統合**: 各 `k8s/*/README.md` を TechDocs として Backstage でホスティング
4. **Scaffolder テンプレート**: 新しい k8s アプリのボイラープレートを自動生成

---

## ArgoCD プラグインの設定

`appConfig.argocd` に以下を追加することで ArgoCD と連携できる:

```yaml
argocd:
  baseUrl: http://argocd.homelab.local
  username: admin
  password: Argocd12345
  appLocatorMethods:
    - type: config
      instances:
        - name: homelab
          url: http://argocd.homelab.local
          username: admin
          password: Argocd12345
```

---

## TechDocs の設定

各サービスのディレクトリに `mkdocs.yml` を置くと Backstage が自動的にドキュメントをビルドする。

```yaml
# mkdocs.yml
site_name: My Service
docs_dir: docs
nav:
  - Home: index.md
  - API Reference: api.md
```
