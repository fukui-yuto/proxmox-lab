# Logging 詳細ガイド — Elasticsearch / Fluent Bit / Kibana

## このスタックが解決する問題

Kubernetes では Pod が複数のノードに分散して動いており、ログが各ノードのファイルに散らばっている。
Pod が再起動するとそのログは消える。
Logging スタックはこれらのログを一箇所に集めて検索・分析できるようにする。

```
問題: ログが分散している
Pod A (node01) のログ → /var/log/containers/...
Pod B (node02) のログ → /var/log/containers/...
Pod C (node03) のログ → /var/log/containers/...

解決: Fluent Bit が全ノードで収集 → Elasticsearch に集約 → Kibana で検索
```

---

## Fluent Bit

### 概念

**軽量なログ収集・転送エージェント**。
各 k3s ノードに DaemonSet として配置され、そのノード上の全コンテナのログを収集する。

```
各ノードのコンテナログ (/var/log/containers/*.log)
    ↓  Fluent Bit が読み取り・パース
Elasticsearch に転送
```

### Fluent Bit のパイプライン

Fluent Bit は以下のパイプラインでログを処理する:

```
INPUT → FILTER → OUTPUT
```

| ステージ | 役割 | このラボの設定 |
|---------|------|--------------|
| INPUT | ログの入力元 | Kubernetes コンテナログ (`/var/log/containers/*.log`) |
| FILTER | ログの加工 | Kubernetes メタデータ (Pod名/Namespace等) を付与 |
| OUTPUT | 転送先 | Elasticsearch |

### Kubernetes フィルターが付与するフィールド

Fluent Bit は各ログに自動的に以下のフィールドを付加する:

```json
{
  "log": "ERROR: connection refused",
  "kubernetes": {
    "pod_name": "nginx-abc123",
    "namespace_name": "default",
    "container_name": "nginx",
    "labels": {
      "app": "nginx"
    },
    "host": "k3s-worker01"
  }
}
```

これにより「どの Pod のログか」「どの Namespace か」で絞り込み検索ができる。

---

## Elasticsearch

### 概念

**全文検索エンジン + 分析データベース**。
大量のログテキストを高速に検索・集計できる。
内部的には Apache Lucene を使用しており、転置インデックスという仕組みで高速検索を実現している。

### 転置インデックスとは

通常のDB (行→内容を検索) と逆に、単語→どのドキュメントに含まれるか を事前に構築したもの。

```
通常のDB: ドキュメントIDから内容を引く
転置インデックス: 単語からドキュメントIDを引く

"ERROR" → [doc1, doc5, doc9, ...]  ← 即座に検索できる
```

### 主要な概念

| 概念 | SQL の対応 | 説明 |
|------|-----------|------|
| Index | Table | データの保存単位。このラボでは `fluent-bit-YYYY.MM.DD` 形式 |
| Document | Row | 1件のログレコード (JSON) |
| Field | Column | JSON のキー (`log`, `kubernetes.pod_name` 等) |
| Shard | パーティション | インデックスを分割して並列処理する単位 |
| Replica | レプリカ | シャードのコピー (冗長化) |

### このラボでの設定

シングルノード構成のため Replica は 0 に設定している:

```bash
# Replica を 0 にしないとクラスター状態が yellow になる
curl -X PUT http://localhost:9200/_settings \
  -H 'Content-Type: application/json' \
  -d '{"index":{"number_of_replicas":0}}'
```

**なぜ yellow になるのか:**
- Elasticsearch はデフォルトでシャードのレプリカを1つ持とうとする
- シングルノードでは別ノードにレプリカを配置できないため未割り当てになる
- 未割り当てのシャードがあると `yellow` → `0` にすると `green`

### Elasticsearch API の基本

```bash
# クラスター状態確認
curl http://localhost:9200/_cluster/health

# インデックス一覧
curl http://localhost:9200/_cat/indices?v

# 特定インデックスのドキュメントを検索 (例: ERRORログ)
curl -X GET http://localhost:9200/fluent-bit-*/_search \
  -H 'Content-Type: application/json' \
  -d '{
    "query": {
      "match": {
        "log": "ERROR"
      }
    }
  }'
```

---

## Kibana

### 概念

**Elasticsearch のデータを可視化・検索する Web UI**。
ログの全文検索、時系列グラフ、フィルタリングなどを GUI で操作できる。

### 主要機能

#### Discover (ログ検索)

最もよく使う機能。時系列でログを検索・フィルタリングできる。

```
時間範囲を指定 → KQL でフィルタ → ログ一覧を表示

例: kubernetes.namespace_name: "monitoring" AND log: "error"
```

**KQL (Kibana Query Language) の例:**

```
# Namespace で絞り込み
kubernetes.namespace_name: "monitoring"

# ログ内容で絞り込み
log: "ERROR"

# AND 条件
kubernetes.pod_name: "prometheus-*" AND log: "WARN"

# 時間範囲は UI の右上で設定 (Last 1 hour など)
```

#### Dashboard (ダッシュボード)

Discover で作ったクエリをグラフ化してダッシュボードにまとめられる。

#### Index Pattern

Kibana で検索するインデックスのパターンを定義する。
このラボでは `fluent-bit-*` を使用 (日付ローテーションに対応)。

---

## ログの流れ (全体像)

```
k3s ノード (各ノードに Fluent Bit)
├─ /var/log/containers/prometheus-xxx.log
├─ /var/log/containers/grafana-xxx.log
└─ /var/log/containers/nginx-xxx.log
         ↓ 収集・パース・メタデータ付与
Elasticsearch (logging namespace)
├─ Index: fluent-bit-2024.01.01
├─ Index: fluent-bit-2024.01.02
└─ Index: fluent-bit-2024.01.03
         ↓ 検索・可視化
Kibana (http://kibana.homelab.local)
Grafana Explore (Elasticsearch データソース)
```

---

## よく使うコマンド

```bash
# 全 Pod の状態確認
kubectl get pods -n logging

# Fluent Bit のログ (転送エラーがないか確認)
kubectl logs -n logging -l app.kubernetes.io/name=fluent-bit --tail=50

# Elasticsearch のクラスター状態
kubectl exec -n logging elasticsearch-master-0 -- \
  curl -s http://localhost:9200/_cluster/health | python3 -m json.tool

# インデックス一覧 (ログが届いているか確認)
kubectl exec -n logging elasticsearch-master-0 -- \
  curl -s http://localhost:9200/_cat/indices?v

# Kibana のログ
kubectl logs -n logging -l app=kibana --tail=50

# Elasticsearch のディスク使用量
kubectl exec -n logging elasticsearch-master-0 -- \
  curl -s http://localhost:9200/_cat/allocation?v
```

---

## トラブルシューティング

### ログが Kibana に表示されない

**1. Fluent Bit が動いているか確認**
```bash
kubectl get pods -n logging -l app.kubernetes.io/name=fluent-bit
# → 全ノード分の Pod が Running であること
```

**2. Fluent Bit の転送エラー確認**
```bash
kubectl logs -n logging -l app.kubernetes.io/name=fluent-bit | grep -i error
```

**3. Elasticsearch にインデックスが作られているか確認**
```bash
kubectl exec -n logging elasticsearch-master-0 -- \
  curl -s http://localhost:9200/_cat/indices?v | grep fluent-bit
```

**4. Kibana の Index Pattern が正しいか確認**
- Kibana UI → Stack Management → Index Patterns → `fluent-bit-*` が存在するか

### Elasticsearch が yellow のまま

```bash
# Replica を 0 に設定して green にする
kubectl exec -n logging elasticsearch-master-0 -- \
  curl -s -X PUT http://localhost:9200/_settings \
  -H 'Content-Type: application/json' \
  -d '{"index":{"number_of_replicas":0}}'
```
