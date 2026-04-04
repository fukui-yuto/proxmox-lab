# ArgoCD 詳細ガイド — GitOps 継続的デリバリー

## このツールが解決する問題

Kubernetes へのデプロイを手動でやると以下の問題が起きる:

```
問題:
  - kubectl apply を手動で実行するのを忘れる
  - 誰かが kubectl で直接変更してしまい、Git と実際の状態がズレる
  - 「今クラスターで動いているのはどのバージョンか」がわからない
  - ロールバックが手動で大変

解決:
  ArgoCD が Git を常に監視し、自動的にクラスターに同期する
  Git が唯一の真実 (Single Source of Truth)
```

---

## GitOps とは

**Git リポジトリをシステムの「あるべき姿」の唯一の正解として扱う運用手法**。

```
従来の運用:
  開発者 → kubectl apply → クラスター
  (Gitと実際の状態が乖離するリスクがある)

GitOps:
  開発者 → Git push → ArgoCD が検知 → クラスターに自動反映
  (Gitが唯一の正解、クラスターは常にGitと一致)
```

**GitOps の4原則 (OpenGitOps):**
1. **宣言的 (Declarative):** あるべき姿を YAML で宣言する
2. **バージョン管理 (Versioned):** Git で全変更履歴を管理する
3. **自動プル (Pulled automatically):** エージェントが Git から自動的に取得する
4. **継続的調整 (Continuously reconciled):** 定期的に実際の状態とあるべき姿を一致させる

---

## ArgoCD のコンポーネント

```
┌─────────────────────────────────────────────────────┐
│  ArgoCD                                             │
│                                                     │
│  API Server       ← CLI/UI/外部からのリクエスト処理   │
│  Repository Server← Git リポジトリからマニフェスト取得 │
│  Application Controller ← 実際のクラスターと照合・同期 │
│  ApplicationSet Controller ← Application を自動生成  │
│  Notifications Controller  ← Slack等への通知         │
│  Redis            ← キャッシュ                       │
└─────────────────────────────────────────────────────┘
```

### Application Controller の動作

Application Controller は **Desired State (あるべき姿)** と **Live State (実際の状態)** を比較し続ける。

```
Git (あるべき姿)         クラスター (実際の状態)
  replicas: 3      vs      replicas: 2  ← 差分あり → 同期
  image: v1.2.0    vs      image: v1.2.0 ← 同じ → OK
```

---

## Application リソース

ArgoCD における「何を」「どこから」「どこに」デプロイするかの定義。

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: monitoring          # Application の名前
  namespace: argocd
spec:
  project: default

  source:
    repoURL: https://github.com/xxx/proxmox-lab  # Git リポジトリ
    targetRevision: HEAD                          # ブランチ/タグ/コミット
    path: k8s/monitoring                          # リポジトリ内のパス

  destination:
    server: https://kubernetes.default.svc        # デプロイ先クラスター
    namespace: monitoring                         # デプロイ先 Namespace

  syncPolicy:
    automated:           # 自動同期の設定
      prune: true        # Git から削除されたリソースをクラスターからも削除
      selfHeal: true     # 手動変更を Git の状態に自動で戻す
```

### selfHeal とは

`selfHeal: true` の場合、誰かが `kubectl` で直接変更しても自動的に Git の状態に戻される。

```
kubectl scale deployment nginx --replicas=5
  ↓  (ArgoCD が検知)
ArgoCD が replicas: 3 (Git の値) に自動で戻す
```

これにより「クラスターの状態は常に Git と一致する」が保証される。

---

## Sync (同期) の仕組み

### Sync Wave

複数の Application ��順番に起動する仕組み。このラボで NIC ハング対策として使用している。

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "3"  # Wave 3 で起動
```

**動作:**
1. Wave 0 の全 Application が Healthy になるまで待つ
2. Wave 1 を起動 → Healthy になるまで待つ
3. Wave 2 を起動 → ...

```
Wave 0: kyverno ─────────────────────────────────────┐
Wave 1: kyverno-policies ───────────────────────────┐ │ 全て Healthy になったら次へ
Wave 2: vault ──────────────────────────────────────┤ │
Wave 3: monitoring ─────────────────────────────────┘ │
...                                                    ↓ 順番に起動
```

### Sync Hook

同期の特定タイミングでジョブを実行する仕組み。

```yaml
metadata:
  annotations:
    argocd.argoproj.io/hook: PreSync     # 同期前に実行
    argocd.argoproj.io/hook: PostSync    # 同期後に実行
    argocd.argoproj.io/hook: SyncFail   # 同期失敗時に実行
```

---

## Helm + ArgoCD の使い方

このラボでは多くのアプリを Helm chart からデプロイしている。
ArgoCD は Helm を内蔵しており、直接 Helm chart を参照できる。

```yaml
spec:
  sources:
    - repoURL: https://prometheus-community.github.io/helm-charts  # Helm リポジトリ
      chart: kube-prometheus-stack                                   # Chart 名
      targetRevision: "61.3.2"                                      # Chart バージョン
      helm:
        valueFiles:
          - $values/k8s/monitoring/values.yaml   # values ファイルの参照

    - repoURL: https://github.com/fukui-yuto/proxmox-lab  # values ファイルの Git リポジトリ
      targetRevision: HEAD
      ref: values   # "$values" として参照される
```

**`$values` の仕組み:**
2つ目の source を `ref: values` として登録することで、`$values/...` で参照できる。
これにより Helm chart は外部リポジトリから取得しつつ、values は自分の Git リポジトリで管理できる。

---

## App of Apps パターン

ArgoCD の Application 自体を ArgoCD で管理するパターン。

```
root Application (Git で管理)
    ↓ 同期
  monitoring Application
  logging Application
  tracing Application
  ...
```

このラボの `k8s/argocd/apps/` ディレクトリがこれに相当する。
ArgoCD をインストールした後、`apps/` 以下の Application を適用するだけで全アプリが管理下に入る。

---

## ArgoCD CLI コマンドリファレンス

```bash
# ログイン
argocd login argocd.homelab.local --username admin --insecure

# Application 一覧
argocd app list

# Application の���態確認
argocd app get monitoring

# 手動同期
argocd app sync monitoring

# 差分確認 (Git vs クラスター)
argocd app diff monitoring

# Application のログ確認
argocd app logs monitoring

# ロールバック (1つ前の状態に戻す)
argocd app rollback monitoring

# Application の削除 (--cascade でリソースも削除)
argocd app delete harbor --cascade

# 全 Application の同期状態確認
argocd app list -o wide
```

---

## Application の状態と意味

| 状態 | 意味 |
|------|------|
| `Synced` | Git とクラスターが一致している |
| `OutOfSync` | Git とクラスターに差分がある |
| `Healthy` | 全リソースが正常稼働中 |
| `Progressing` | デプロイ中 |
| `Degraded` | 一部リソースに問題がある |
| `Missing` | リソースがクラスターに存在しない |
| `Unknown` | 状態を確認できない |

---

## よく使うコマンド

```bash
# ArgoCD Pod の状態確認
kubectl get pods -n argocd

# ArgoCD Server のログ (UI/API のログ)
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server --tail=50

# Application Controller のログ (同期ログ)
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller --tail=50

# Repo Server のログ (Git 接続ログ)
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server --tail=50

# 全 Application の同期を強制実行
for app in $(argocd app list -o name); do
  argocd app sync $app
done
```

---

## トラブルシューティング

### Application が OutOfSync のまま自動同期しない

```bash
# 差分を確認
argocd app diff monitoring

# 手動で強制同期
argocd app sync monitoring --force

# selfHeal が有効か確認
argocd app get monitoring | grep "Auto Sync"
```

### Git リポジトリに接続できない

```bash
# Repo Server のログを確認
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server | grep -i error

# リポジトリ接続テスト (ArgoCD UI)
# Settings → Repositories → 対象リポジトリ → Connection Status
```

### Helm values が反映されない

ArgoCD の Repo Server がキャッシュしている場合がある。

```bash
# Application を手動でリフレッシュ
argocd app get monitoring --hard-refresh
```
