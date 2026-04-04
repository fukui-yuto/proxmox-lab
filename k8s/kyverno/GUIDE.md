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
