# Tests — Playwright E2E / API テスト

ホームラボの Web UI と AIOps API を自動テストする [Playwright](https://playwright.dev/) プロジェクト。

---

## セットアップ

```bash
cd tests
npm install
npx playwright install chromium
```

### hosts ファイルへの追記 (Windows)

テスト対象のホスト名を解決できるよう、未設定の場合は追記する。

```powershell
$ip = "192.168.210.24"
$entries = @(
  "grafana.homelab.local",
  "kibana.homelab.local",
  "argocd.homelab.local",
  "argo-workflows.homelab.local",
  "alert-summarizer.homelab.local"
)
$entries | ForEach-Object { Add-Content "C:\Windows\System32\drivers\etc\hosts" "$ip  $_" }
```

---

## 実行

```bash
# 全テスト (E2E + API)
npm test

# E2E テストのみ (Grafana / ArgoCD / Kibana / Argo Workflows)
npm run test:ui

# API テストのみ (alert-summarizer)
npm run test:api

# ブラウザを表示しながら実行 (デバッグ時)
npm run test:headed

# HTML レポートを開く
npm run report
```

---

## テスト一覧

### E2E テスト (`tests/e2e/`)

| ファイル | テスト対象 | 確認内容 |
|---|---|---|
| `grafana.spec.ts` | `grafana.homelab.local` | ログイン・Log Anomaly Detection ダッシュボード・アラートルール |
| `argocd.spec.ts` | `argocd.homelab.local` | aiops 系アプリの Synced / Healthy ステータス |
| `kibana.spec.ts` | `kibana.homelab.local` | Discover ページ・fluent-bit インデックスの存在 |
| `argo-workflows.spec.ts` | `argo-workflows.homelab.local` | WorkflowTemplate の存在確認 |

### API テスト (`tests/api/`)

| ファイル | テスト対象 | 確認内容 |
|---|---|---|
| `alert-summarizer.spec.ts` | `alert-summarizer.homelab.local` | `/health` レスポンス・`/webhook` 正常系/異常系 |

---

## 環境変数

デフォルト値を上書きする場合は環境変数で指定する。

| 変数 | デフォルト | 説明 |
|---|---|---|
| `GRAFANA_URL` | `http://grafana.homelab.local` | Grafana URL |
| `GRAFANA_USER` | `admin` | Grafana ユーザー |
| `GRAFANA_PASSWORD` | `changeme` | Grafana パスワード |
| `ARGOCD_URL` | `http://argocd.homelab.local` | ArgoCD URL |
| `ARGOCD_PASSWORD` | `Argocd12345` | ArgoCD admin パスワード |
| `KIBANA_URL` | `http://kibana.homelab.local` | Kibana URL |
| `ARGO_WORKFLOWS_URL` | `http://argo-workflows.homelab.local` | Argo Workflows URL |
| `ALERT_SUMMARIZER_URL` | `http://alert-summarizer.homelab.local` | alert-summarizer URL |

```bash
# 例: パスワードを上書きして実行
GRAFANA_PASSWORD=mypassword npm run test:ui
```

---

## レポート

テスト失敗時はスクリーンショットと動画が `test-results/` に保存される。

```bash
npm run report   # playwright-report/index.html をブラウザで開く
```
