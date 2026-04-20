# Kyverno 詳細ガイド — Kubernetes ポリシーエンジン

## このツールが解決する問題

Kubernetes では誰でも (権限さえあれば) 以下のようなリソースを作れてしまう:

```yaml
# 問題のある Pod の例
containers:
  - name: app
    image: nginx:latest      # ← latest タグ: バージョン管理不能
    # resources が未設定    ← ノードのリソースを使い放題になる
```

Kyverno はこれらを自動的に検知・拒否・修正するポリシーエンジン。

---

## Kubernetes Admission Controller とは

Kyverno を理解するには、まず Admission Controller の仕組みを知る必要がある。

### API リクエストのライフサイクル

```
kubectl apply -f pod.yaml
        ↓
1. Authentication    (誰がリクエストしているか確認)
2. Authorization     (権限があるか確認)
3. Admission Control (ポリシーチェック) ← Kyverno はここ
        ↓
4. etcd に保存 → Pod 起動
```

### Webhook の仕組み

Kyverno は Kubernetes に Webhook として登録される。
リソース作成・更新リクエストが API Server に来ると、API Server が Kyverno に転送して判断を仰ぐ。

```
kubectl apply
    ↓
Kubernetes API Server
    ↓ (Webhook 呼び出し)
Kyverno
    ↓ ポリシー評価
    ├─ OK → 作成許可
    └─ NG → 拒否 (enforce) or 警告 (audit)
```

**これが「Kyverno が落ちるとクラスター操作不能になる」理由:**
Kyverno が応答しないと API Server がリクエストを処理できない
(`failurePolicy: Fail` の場合)。

---

## Kyverno の3つの機能

### 1. Validate (検証)

ポリシーに違反するリソースを**検知・拒否**する。

```yaml
# 例: latest タグを禁止するポリシー
spec:
  rules:
    - name: disallow-latest-tag
      validate:
        message: ":latest タグは使用禁止です"
        pattern:
          spec:
            containers:
              - image: "!*:latest"
```

### 2. Mutate (変換)

リソース作成時に**自動的に内容を書き換える**。

```yaml
# 例: resources.limits が未設定なら自動で追加する
spec:
  rules:
    - name: add-default-limits
      mutate:
        patchStrategicMerge:
          spec:
            containers:
              - name: "*"
                resources:
                  limits:
                    memory: "256Mi"
                    cpu: "500m"
```

### 3. Generate (生成)

リソース作成時に**関連リソースを自動生成**する。

```yaml
# 例: Namespace 作成時に NetworkPolicy を自動作成する
spec:
  rules:
    - name: add-network-policy
      generate:
        kind: NetworkPolicy
        # ...
```

---

## audit vs enforce モード

| モード | 動作 | 用途 |
|-------|------|------|
| **audit** | 違反を記録するが作成は許可 | まず現状把握。既存リソースを壊さずに導入 |
| **enforce** | 違反するリソースの作成を拒否 | 厳格にルールを適用したい場合 |

### このラボのポリシー (全て audit モード)

```yaml
spec:
  validationFailureAction: audit  # ← 警告のみ、拒否はしない
```

**audit にしている理由:**
- Helm chart が内部でリソースを作成する際にポリシー違反になる可能性がある
- enforce にすると既存の Helm リリースが壊れる可能性がある
- まずは audit で問題を把握してから enforce に移行するのが安全

---

## このラボのポリシー解説

### require-resource-limits.yaml

```yaml
# 全コンテナに CPU/メモリの limits を必須にする
pattern:
  spec:
    containers:
      - name: "*"
        resources:
          limits:
            memory: "?*"  # 何らかの値が設定されていること
            cpu: "?*"
```

**なぜ必要か:**
limits がないと、1つのコンテナがノードのリソースを使い切ってしまい他の Pod が動かなくなる
(「ノイジーネイバー問題」)。

### disallow-latest-tag.yaml

```yaml
# :latest タグのイメージを禁止
pattern:
  spec:
    containers:
      - image: "!*:latest"
```

**なぜ必要か:**
`:latest` は「その時点の最新」を指すため、同じマニフェストでも時間によって
異なるイメージが使われる。再現性がなく、いつの間にか動作が変わることがある。
`nginx:1.25.3` のように具体的なバージョンを指定するべき。

### require-labels.yaml

```yaml
# app ラベルを必須にする
pattern:
  metadata:
    labels:
      app: "?*"
```

**なぜ必要か:**
ラベルがないと Service のセレクターで Pod を特定できない。
また、監視・ログ収集でどのアプリのリソースか識別できなくなる。

---

## PolicyReport — 違反レポートの確認

audit モードで検知した違反は PolicyReport として記録される。

```bash
# 全 Namespace のポリシーレポート確認
kubectl get policyreport -A

# 詳細確認
kubectl describe policyreport -n monitoring

# 出力例
Results:
  Message: validation rule 'require-limits' passed.
  Policy:  require-resource-limits
  Result:  pass
  ...
  Message: Validation error: ":latest タグは使用禁止です"
  Policy:  disallow-latest-tag
  Result:  fail   ← ここに違反が記録される
```

---

## enforce モードへの段階的移行

```
1. audit モードで運用 → PolicyReport で違反を洗い出す
2. 違反しているリソースを修正する
3. enforce モードに変更する
```

```bash
# 違反の多いポリシーを確認
kubectl get policyreport -A -o json | \
  python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data['items']:
    ns = item['metadata']['namespace']
    for r in item.get('results', []):
        if r['result'] == 'fail':
            print(f\"{ns}: {r['policy']} - {r['message']}\")
"
```

---

## よく使うコマンド

```bash
# Kyverno Pod の状態確認
kubectl get pods -n kyverno

# 登録されているポリシー一覧
kubectl get clusterpolicy

# 特定ポリシーの詳細
kubectl describe clusterpolicy require-resource-limits

# ポリシーレポート確認
kubectl get policyreport -A

# Webhook 設定の確認 (Kyverno が登録している Webhook)
kubectl get validatingwebhookconfigurations | grep kyverno
kubectl get mutatingwebhookconfigurations | grep kyverno
```

---

## トラブルシューティング

### kubectl apply がタイムアウトする

Kyverno の Pod が落ちている可能性がある。

```bash
kubectl get pods -n kyverno
# → Pod が Running でなければ原因を調査

kubectl logs -n kyverno -l app.kubernetes.io/name=kyverno --tail=50
```

### ポリシー違反でリソースが作れない

```bash
# エラーメッセージを確認
kubectl apply -f my-resource.yaml
# → "admission webhook denied the request: ..."
# → メッセージにどのポリシーに違反しているか書いてある

# ポリシーを一時的に audit に変更して回避
kubectl patch clusterpolicy require-resource-limits \
  --type=merge \
  -p '{"spec":{"validationFailureAction":"audit"}}'
```

---

## ファイル構成と各ファイルのコード解説

### ファイル構成一覧

```
k8s/kyverno/
├── namespace.yaml                          # Kyverno 用 Namespace 定義
├── values-kyverno.yaml                     # Kyverno Helm chart のカスタム values
└── policies/
    ├── require-resource-limits.yaml        # リソース制限必須化ポリシー
    ├── disallow-latest-tag.yaml            # latest タグ禁止ポリシー
    └── require-labels.yaml                 # app ラベル必須化ポリシー
```

| ファイル | 役割 |
|---------|------|
| `namespace.yaml` | Kyverno のコンポーネントがデプロイされる Namespace を作成 |
| `values-kyverno.yaml` | Helm chart (kyverno/kyverno v3.2.6) のカスタマイズ設定 |
| `policies/require-resource-limits.yaml` | 全コンテナに CPU/メモリ limits を要求する ClusterPolicy |
| `policies/disallow-latest-tag.yaml` | `:latest` タグのイメージを禁止する ClusterPolicy |
| `policies/require-labels.yaml` | Pod/Deployment 等に `app` ラベルを要求する ClusterPolicy |

---

### namespace.yaml

```yaml
apiVersion: v1          # Kubernetes コア API (v1 は Namespace など基本リソース)
kind: Namespace         # リソースの種類: Namespace
metadata:
  name: kyverno         # Namespace 名 — Kyverno の全コンポーネントがここにデプロイされる
```

**解説:**

- Kubernetes のリソースは Namespace で論理的にグループ化される
- Kyverno 専用の Namespace を分離することで、他アプリとの干渉を防ぐ
- このラボでは ArgoCD が `namespace.yaml` を最初に適用し、その後 Helm release をこの Namespace にインストールする
- Kyverno 自身のポリシー適用対象から `kyverno` Namespace は除外されている (ポリシーの `namespaces: "!kyverno"` で実現)

---

### values-kyverno.yaml — Helm chart カスタム設定の全解説

この values ファイルは Kyverno Helm chart (v3.2.6) のデフォルト値を上書きし、このラボ環境に最適化するためのもの。

#### crds.install: false の理由

```yaml
# -------------------------------------------------------------------
# CRD 管理を無効化 (annotations サイズ超過を回避)
# -------------------------------------------------------------------
crds:
  install: false    # Helm による CRD インストールを無効化
```

**背景:**
- Kyverno の CRD (Custom Resource Definition) は非常にサイズが大きい (数百KB)
- ArgoCD はリソースに `kubectl.kubernetes.io/last-applied-configuration` アノテーションを付与するが、
  このアノテーションのサイズ上限は **262,144 bytes** (256KB)
- Kyverno CRD はこの上限を超えるため、ArgoCD が CRD を管理しようとするとエラーになる
- 解決策: `crds.install: false` にして Helm/ArgoCD による CRD 管理を無効化し、
  事前に手動 (または別の仕組み) でインストールされた CRD をそのまま使う

#### admissionController — ポリシー評価の中核コンポーネント

```yaml
admissionController:
  replicas: 1       # ラボ環境のためレプリカ数を 1 に削減 (本番なら 3 推奨)

  # master ノード (k3s-master) へのスケジューリングを禁止
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: node-role.kubernetes.io/control-plane
              operator: DoesNotExist   # このラベルが「存在しない」ノードにのみ配置

  # CPU/メモリのリソース制限
  resources:
    requests:       # スケジューラーが確保する最低リソース量
      cpu: 100m         # 0.1 CPU コア
      memory: 128Mi     # 128 メビバイト
    limits:         # コンテナが使える最大リソース量
      cpu: 300m         # 0.3 CPU コア
      memory: 384Mi     # 384 メビバイト
```

**admissionController の役割:**
- Kubernetes API Server からの Webhook リクエストを受信し、ポリシーを評価する
- リソースの作成・更新・削除時にリアルタイムで Validate/Mutate/Generate を実行
- **これが停止するとクラスター操作が不能になる** (failurePolicy の設定次第)

**master 回避 (nodeAffinity) の理由:**
- k3s-master は 6GB RAM で k3s server プロセスと共存している
- ここに Kyverno を配置すると API Server の応答遅延が発生し、
  etcd のリース更新が失敗 → クラスター不安定化につながる
- `node-role.kubernetes.io/control-plane` ラベルが付いたノード (= k3s-master) を除外する

#### backgroundController — 既存リソースへのポリシー適用

```yaml
backgroundController:
  nodeAffinity:     # (admissionController と同じ master 回避設定)
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: node-role.kubernetes.io/control-plane
              operator: DoesNotExist
  resources:
    requests:
      cpu: 50m          # 0.05 CPU コア (バックグラウンド処理のため軽量)
      memory: 64Mi
    limits:
      cpu: 100m
      memory: 128Mi
```

**backgroundController の役割:**
- ポリシーで `background: true` が設定されている場合、**既に存在するリソース** に対してもポリシーを評価する
- 新規作成時だけでなく、ポリシー適用前から存在するリソースの違反も検知できる
- admissionController のようにリアルタイムではなく、定期的にスキャンする

#### cleanupController — TTL ベースのリソース削除

```yaml
cleanupController:
  nodeAffinity:     # (master 回避設定)
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: node-role.kubernetes.io/control-plane
              operator: DoesNotExist
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      cpu: 100m
      memory: 128Mi
```

**cleanupController の役割:**
- Kyverno の CleanupPolicy リソースに基づいて、条件に合致するリソースを自動削除する
- 例: 「1時間以上前に作成された Job を自動削除」などの TTL ベースのクリーンアップ
- 古い PolicyReport や不要な一時リソースの自動廃棄に活用できる

#### reportsController — ポリシーレポート生成

```yaml
reportsController:
  nodeAffinity:     # (master 回避設定)
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: node-role.kubernetes.io/control-plane
              operator: DoesNotExist
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      cpu: 100m
      memory: 128Mi
```

**reportsController の役割:**
- audit モードで検知したポリシー違反を PolicyReport / ClusterPolicyReport リソースとして生成する
- `kubectl get policyreport -A` で確認できるレポートはこのコントローラーが作成している
- Grafana ダッシュボードや外部ツールとの連携に活用できる

#### features.forceFailurePolicyIgnore — Kyverno ダウン時の安全弁

```yaml
features:
  forceFailurePolicyIgnore:
    enabled: true   # Kyverno ダウン時に全リクエストを「許可」に倒す
```

**解説:**

Webhook の `failurePolicy` には 2 つの設定がある:

| failurePolicy | Kyverno が応答しない場合の動作 |
|---------------|-------------------------------|
| `Fail` | リクエストを**拒否**する (安全だが運用に支障) |
| `Ignore` | リクエストを**許可**する (ポリシー違反が通る可能性あり) |

`forceFailurePolicyIgnore: true` にすると:
- Kyverno が落ちた場合でも Kubernetes クラスターの操作が止まらない
- Pod のスケジューリング・Service の更新などが引き続き動作する
- トレードオフ: Kyverno ダウン中はポリシーが効かないため、違反リソースが作られる可能性がある

**このラボで有効にしている理由:**
- replicas=1 のため、Pod 再起動中に Webhook が応答不能になりやすい
- ラボ環境ではクラスター操作不能のリスクの方がポリシー一時無効より深刻

#### cleanupJobs — Harbor プロキシ経由のイメージ指定

```yaml
# policyReportsCleanup (Helm hook で実行されるジョブ)
policyReportsCleanup:
  image:
    registry: harbor.homelab.local                    # Harbor レジストリ
    repository: dockerhub-proxy/bitnami/kubectl       # Docker Hub のプロキシキャッシュ経由
    tag: '1.31'                                       # kubectl バージョン

# cleanupJobs (定期クリーンアップジョブ)
cleanupJobs:
  admissionReports:           # Admission レポートの古いエントリを削除
    image:
      registry: harbor.homelab.local
      repository: dockerhub-proxy/bitnami/kubectl
      tag: '1.31'
  clusterAdmissionReports:    # クラスタースコープの Admission レポートを削除
    image: ...                # (同上)
  updateRequests:             # 古い Update リクエストを削除
    image: ...                # (同上)
  ephemeralReports:           # 一時レポートを削除
    image: ...                # (同上)
  clusterEphemeralReports:    # クラスタースコープの一時レポートを削除
    image: ...                # (同上)
```

**Harbor プロキシ経由にしている理由:**
- このラボでは Docker Hub への直接アクセスが不可 (レートリミット対策・ネットワーク制限)
- Harbor の「プロキシキャッシュ」機能を使い、Docker Hub イメージをキャッシュ経由で取得する

**bitnami/kubectl を選択した理由:**
- Kyverno の Cleanup Job は内部で `/bin/bash -c "kubectl ..."` を実行する (Helm chart がハードコード)
- `cgr.dev/chainguard/kubectl` は最小構成で `/bin/bash` が存在しないため使用不可
- `bitnami/kubectl` は非 root ユーザー (UID 1001) で動作し、`/bin/bash` も含むため最適

---

### policies/require-resource-limits.yaml — リソース制限必須化ポリシー

```yaml
---
apiVersion: kyverno.io/v1      # Kyverno ポリシーの API バージョン
kind: ClusterPolicy            # クラスター全体に適用されるポリシー (Namespace スコープなら Policy)
metadata:
  name: require-resource-limits
  annotations:
    # Kyverno のポリシーカタログ用メタデータ (UI 表示や検索に使用)
    policies.kyverno.io/title: "Resource Limits の必須化"
    policies.kyverno.io/category: "Best Practices"
    policies.kyverno.io/severity: medium        # low / medium / high / critical
    policies.kyverno.io/description: >-
      全コンテナに CPU・メモリの resource limits が設定されていることを確認する。
spec:
  validationFailureAction: Audit    # 違反を記録するが拒否はしない
  background: true                  # 既存リソースもバックグラウンドでスキャンする

  rules:
    # ルール 1: 通常のコンテナをチェック
    - name: check-container-resources
      match:
        any:
          - resources:
              kinds:
                - Pod                       # Pod リソースのみ対象
              namespaces:
                - "!kube-system"            # kube-system を除外 (! = NOT)
                - "!kyverno"               # kyverno 自身を除外
      validate:
        message: "全コンテナに resources.limits (cpu, memory) を設定してください。"
        pattern:
          spec:
            containers:
              - name: "*"                   # 全コンテナに対して
                resources:
                  limits:
                    cpu: "?*"              # "?*" = 1文字以上の任意の値が必須
                    memory: "?*"           # (空文字ではダメ)

    # ルール 2: init コンテナもチェック
    - name: check-initcontainer-resources
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - "!kube-system"
                - "!kyverno"
      validate:
        message: "全 initContainer に resources.limits (cpu, memory) を設定してください。"
        pattern:
          spec:
            =(initContainers):             # "=" プレフィックス = フィールドが存在する場合のみ評価
              - name: "*"                   # initContainers がない Pod ではこのルールはスキップされる
                resources:
                  limits:
                    cpu: "?*"
                    memory: "?*"
```

**ポイント解説:**

1. **ClusterPolicy vs Policy:**
   - `ClusterPolicy` はクラスター全体 (全 Namespace) に適用される
   - `Policy` は特定の Namespace にのみ適用される
   - リソース制限は全てのワークロードに適用すべきなので ClusterPolicy を使用

2. **`=(initContainers)` の意味:**
   - `=` プレフィックスは「このフィールドが存在する場合のみ検証する」という条件付きマッチ
   - initContainers は省略可能なフィールドのため、存在しない Pod でエラーにならないようにしている
   - もし `=` なしで書くと、initContainers がない Pod も違反扱いになってしまう

3. **`"?*"` パターン:**
   - `?` は任意の1文字、`*` は0文字以上の任意の文字列
   - 組み合わせると「1文字以上の何らかの値」= 空でなければ OK

4. **Namespace 除外 (`"!kube-system"`, `"!kyverno"`):**
   - kube-system: Kubernetes 自体のシステムコンポーネント (coredns, kube-proxy 等) は制御できない
   - kyverno: 自分自身のポリシーで自分をブロックすると起動不能になるため除外

---

### policies/disallow-latest-tag.yaml — latest タグ禁止ポリシー

```yaml
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-latest-tag
  annotations:
    policies.kyverno.io/title: "latest タグの禁止"
    policies.kyverno.io/category: "Best Practices"
    policies.kyverno.io/severity: medium
    policies.kyverno.io/description: >-
      latest タグを使用したイメージは再現性がなく、予期しない動作を引き起こす可能性がある。
spec:
  validationFailureAction: Audit
  background: true

  rules:
    - name: check-image-tag
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - "!kube-system"
                - "!kyverno"
      validate:
        message: "latest タグの使用は禁止されています。明示的なバージョンタグを使用してください。例: nginx:1.27.0"
        foreach:
          # request.object.spec.containers はリスト — 各要素を element として処理
          - list: "request.object.spec.containers"
            deny:
              conditions:
                any:
                  # 条件 1: タグが省略されている場合 (例: "nginx" → 暗黙的に nginx:latest)
                  - key: "{{ element.image }}"
                    operator: NotIn
                    value: ["*:*"]           # "イメージ名:タグ" の形式でない → タグ省略
                  # 条件 2: 明示的に :latest が指定されている場合
                  - key: "{{ element.image }}"
                    operator: Equals
                    value: "*:latest"        # ワイルドカード: 任意のイメージ名 + :latest

    - name: check-initcontainer-image-tag
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - "!kube-system"
                - "!kyverno"
      validate:
        message: "initContainer に latest タグの使用は禁止されています。"
        foreach:
          # "=(initContainers)" — initContainers が存在する場合のみ処理
          - list: "request.object.spec.=(initContainers)"
            deny:
              conditions:
                any:
                  - key: "{{ element.image }}"
                    operator: NotIn
                    value: ["*:*"]
                  - key: "{{ element.image }}"
                    operator: Equals
                    value: "*:latest"
```

**ポイント解説:**

1. **foreach ループ:**
   - `pattern` ではなく `foreach` + `deny` を使用している
   - `pattern` は構造的なマッチングに向いているが、「:latest でないこと」のような否定条件は
     `foreach` で各コンテナを個別にチェックする方が正確
   - `element` は foreach ループの現在のアイテムを参照する変数

2. **2 つの deny 条件 (any で結合):**
   ```
   条件 1: image が "*:*" パターンに合致しない → タグが省略されている
           例: "nginx" (タグなし → Docker は暗黙的に :latest を使う)

   条件 2: image が "*:latest" に一致する → 明示的に :latest を指定
           例: "nginx:latest"
   ```
   - `any` なので、どちらか一方でも該当すれば deny (違反) になる

3. **なぜ `:latest` がダメなのか:**
   - `nginx:latest` は「その瞬間の最新バージョン」を指す可変タグ
   - 月曜に pull した `nginx:latest` と金曜に pull した `nginx:latest` は別のイメージの可能性がある
   - 障害発生時に「どのバージョンが動いていたか」追跡できない
   - `nginx:1.27.0` のような固定タグなら常に同じイメージが使われる (再現性の担保)

---

### policies/require-labels.yaml — app ラベル必須化ポリシー

```yaml
---
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-labels
  annotations:
    policies.kyverno.io/title: "app ラベルの必須化"
    policies.kyverno.io/category: "Best Practices"
    policies.kyverno.io/severity: low           # 重要度は低め (運用改善レベル)
    policies.kyverno.io/description: >-
      全 Pod に app ラベルが設定されていることを確認する。
spec:
  validationFailureAction: Audit
  background: true

  rules:
    # ルール 1: Pod に直接 app ラベルを要求
    - name: check-app-label
      match:
        any:
          - resources:
              kinds:
                - Pod                   # 直接作成される Pod をチェック
              namespaces:
                - "!kube-system"
                - "!kyverno"
      validate:
        message: "Pod の metadata.labels に 'app' ラベルを設定してください。例: app: my-application"
        pattern:
          metadata:
            labels:
              app: "?*"                 # "app" ラベルに 1文字以上の値が必要

    # ルール 2: Deployment/StatefulSet/DaemonSet の Pod テンプレートもチェック
    - name: check-deployment-app-label
      match:
        any:
          - resources:
              kinds:
                - Deployment            # レプリカ管理 (最も一般的)
                - StatefulSet           # ステートフルアプリ (DB 等)
                - DaemonSet             # 全ノードに1つずつ配置
              namespaces:
                - "!kube-system"
                - "!kyverno"
      validate:
        message: "spec.template.metadata.labels に 'app' ラベルを設定してください。"
        pattern:
          spec:
            template:                   # Pod テンプレート (ここから Pod が生成される)
              metadata:
                labels:
                  app: "?*"            # 生成される Pod にも app ラベルが必要
```

**ポイント解説:**

1. **なぜ 2 つのルールが必要か:**
   - ルール 1: `kubectl run` などで直接作成された Pod をキャッチ
   - ルール 2: Deployment 等の Pod テンプレートをキャッチ
   - Deployment が作る Pod は `.spec.template` から生成されるため、
     そのテンプレートの `.metadata.labels` を検証する必要がある

2. **対象リソースの種類:**
   - `Deployment`: 最も一般的なワークロード (nginx, API サーバー等)
   - `StatefulSet`: 永続データを持つアプリ (PostgreSQL, Elasticsearch 等)
   - `DaemonSet`: 全ノードで動かすエージェント (monitoring agent, CNI 等)

3. **`app` ラベルが重要な理由:**
   - **Service のセレクター**: `Service` は `selector.app: xxx` で Pod にトラフィックを振り分ける
   - **監視**: Prometheus が `app` ラベルでメトリクスを分類する
   - **ログ収集**: Fluent Bit が `app` ラベルでログの送り先を判定する
   - **NetworkPolicy**: `app` ラベルで通信許可対象を指定する

---

### validationFailureAction: Audit vs Enforce の違い (まとめ)

| 項目 | Audit | Enforce |
|------|-------|---------|
| 違反リソースの作成 | **許可する** | **拒否する** |
| 違反の記録 | PolicyReport に記録される | PolicyReport に記録される + API エラーが返る |
| 既存リソースへの影響 | なし | なし (既存リソースは削除されない) |
| ユーザーへのフィードバック | `kubectl get policyreport` で確認 | `kubectl apply` 時にエラーメッセージ表示 |
| 推奨用途 | 導入初期・影響調査 | ルール違反を確実に防ぎたい場合 |

**Audit モードの動作フロー:**

```
kubectl apply -f pod.yaml
    ↓
API Server → Kyverno Webhook
    ↓
ポリシー評価: 違反あり
    ↓
結果: 許可 (Pod 作成される) + PolicyReport に "fail" を記録
    ↓
管理者が後から kubectl get policyreport で確認
```

**Enforce モードの動作フロー:**

```
kubectl apply -f pod.yaml
    ↓
API Server → Kyverno Webhook
    ↓
ポリシー評価: 違反あり
    ↓
結果: 拒否 (Pod 作成されない)
    ↓
ユーザーにエラー: "admission webhook denied the request: ..."
```

**このラボで全ポリシーを Audit にしている理由:**

1. **Helm chart の互換性**: 多くの Helm chart は `resources.limits` を設定しないデフォルト値を持つ。
   Enforce にすると既存の Helm リリースのアップグレードが失敗する可能性がある
2. **段階的導入**: まず Audit で違反状況を把握し、修正してから Enforce に移行するのが安全
3. **学習環境**: ラボでは試行錯誤が多いため、厳格に拒否するより警告に留める方が生産性が高い

**Enforce への移行手順:**

```yaml
# 1. PolicyReport で違反を確認
kubectl get policyreport -A

# 2. 違反しているリソースを全て修正

# 3. ポリシーの validationFailureAction を変更
spec:
  validationFailureAction: Enforce    # Audit → Enforce に変更
```
