# Tracing 詳細ガイド — OpenTelemetry / Grafana Tempo

## このスタックが解決する問題

マイクロサービスでは1つのリクエストが複数のサービスをまたいで処理される。
ログだけでは「どのサービスでどれだけ時間がかかったか」が分からない。

```
問題: 遅いリクエストの原因がわからない
ユーザーリクエスト
  → Service A (10ms)
    → Service B (500ms?) ← ここが遅い？
      → Database (200ms?)
        → Service C (50ms)

解決: 分散トレーシングでリクエスト全体の流れを可視化する
```

---

## 分散トレーシングの基本概念

### Trace と Span

**Trace (トレース):** 1つのリクエストが通過した全処理の記録。ユニークな `trace_id` で識別される。

**Span (スパン):** トレースを構成する個々の処理単位。開始時刻・終了時刻・メタデータを持つ。

```
Trace (trace_id: abc123)
├─ Span: HTTP GET /api/users        [0ms ─────────────── 760ms]
│   ├─ Span: Auth check             [0ms ── 10ms]
│   ├─ Span: DB query users         [10ms ────────── 510ms]  ← ここが遅い
│   └─ Span: Response serialization [510ms ── 760ms]
```

### Trace ID の伝播

サービス間でリクエストが渡される際、HTTP ヘッダーに `trace_id` を付けて渡す。
これにより複数のサービスにまたがる処理を1つの Trace として追跡できる。

```
Service A → HTTP ヘッダー: traceparent: 00-abc123-xxx-01 → Service B → Service C
```

---

## OpenTelemetry

### 概念

**観測可能性 (Observability) のオープンスタンダード**。
メトリクス・ログ・トレースを収集・転送するための統一された仕様とライブラリ群。

以前はトレーシングのツールが乱立していた (Jaeger, Zipkin, etc.)。
OpenTelemetry はそれらを統一する共通規格として CNCF が策定した。

### OpenTelemetry Collector

**テレメトリデータ (メトリクス・ログ・トレース) を受信・変換・転送するプロキシ**。

```
アプリ (OTLP で送信)
    ↓
OTel Collector
├─ Receiver: OTLP, Jaeger, Zipkin 等で受信
├─ Processor: サンプリング、フィルタ、バッチ処理
└─ Exporter: Tempo, Prometheus, Elasticsearch 等に転送
```

**なぜ Collector を挟むのか:**
- アプリが直接 Tempo に送信すると、Tempo の URL をアプリに埋め込む必要がある
- Collector を挟むことでアプリは Collector のエンドポイントだけ知ればよい
- バックエンドを変えてもアプリを変更不要

### このラボでの受信プロトコル

| プロトコル | ポート | 用途 |
|-----------|--------|------|
| OTLP gRPC | 4317 | OpenTelemetry (推奨) |
| OTLP HTTP | 4318 | OpenTelemetry (HTTP) |
| Jaeger gRPC | 14250 | 旧 Jaeger クライアント |
| Jaeger HTTP | 14268 | 旧 Jaeger クライアント (HTTP) |

---

## Grafana Tempo

### 概念

**高スケールなトレースストレージ**。Grafana が開発したトレース専用のデータストア。

Elasticsearch でトレースを保存するとコストが高くなる問題を解決するために作られた。
オブジェクトストレージ (S3, GCS 等) に格納するため、大量のトレースを安価に保存できる。

このラボではシンプルにローカルディスクに保存している。

### Tempo と Prometheus の連携 (Service Graph)

`values.yaml` の Grafana データソース設定でこれを有効化している:

```yaml
- name: Tempo
  jsonData:
    serviceMap:
      datasourceUid: prometheus  # Prometheus と連携
```

これにより Grafana でサービス間の依存関係マップを自動生成できる。

---

## アプリからトレースを送信する方法

### 送信先エンドポイント

クラスター内からは以下に送信する:

```
OTLP gRPC: otel-collector.tracing.svc.cluster.local:4317
OTLP HTTP: otel-collector.tracing.svc.cluster.local:4318
```

### Node.js の例

```javascript
const { NodeSDK } = require('@opentelemetry/sdk-node');
const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-grpc');

const sdk = new NodeSDK({
  traceExporter: new OTLPTraceExporter({
    url: 'grpc://otel-collector.tracing.svc.cluster.local:4317',
  }),
  serviceName: 'my-service',
});

sdk.start();
```

### Python の例

```python
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

provider = TracerProvider()
exporter = OTLPSpanExporter(
    endpoint="otel-collector.tracing.svc.cluster.local:4317",
    insecure=True,
)
provider.add_span_processor(BatchSpanProcessor(exporter))
trace.set_tracer_provider(provider)
```

---

## Grafana でトレースを確認する方法

1. `http://grafana.homelab.local` を開く
2. 左メニュー → **Explore**
3. データソースを **Tempo** に切り替える

### TraceQL (Tempo のクエリ言語)

```
# service.name が my-service のトレースを検索
{ resource.service.name = "my-service" }

# 500ms 以上かかったトレースを検索
{ duration > 500ms }

# エラーが含まれるトレースを検索
{ status = error }

# AND 条件
{ resource.service.name = "my-service" && duration > 100ms }
```

---

## Metrics / Logs / Traces の違い

この3つは「観測可能性の3本柱 (Three Pillars of Observability)」と呼ばれる。

| 種類 | What (何) | When (いつ) | Why (なぜ) |
|------|-----------|-------------|-----------|
| Metrics | CPU 80% | 14:30 に急上昇 | 負荷が高い |
| Logs | `ERROR: DB connection failed` | 14:31 に大量発生 | DB が落ちた |
| Traces | /api/users が 5s かかった | 14:30 から | DB クエリが遅い (スパンで確認) |

3つを組み合わせることで障害の原因を素早く特定できる。
Grafana はこの3つを一元的に可視化できるため、このラボで使っている。

---

## よく使うコマンド

```bash
# Pod の状態確認
kubectl get pods -n tracing

# OTel Collector のログ (受信できているか確認)
kubectl logs -n tracing -l app.kubernetes.io/name=opentelemetry-collector --tail=50

# Tempo の状態確認
kubectl exec -n tracing tempo-0 -- wget -qO- http://localhost:3100/ready

# Tempo の設定確認
kubectl exec -n tracing tempo-0 -- cat /conf/tempo.yaml
```

---

## トラブルシューティング

### Grafana に Trace が表示されない

**1. OTel Collector がトレースを受信しているか確認**
```bash
kubectl logs -n tracing -l app.kubernetes.io/name=opentelemetry-collector | grep -i "trace"
```

**2. Tempo が Ready か確認**
```bash
kubectl exec -n tracing tempo-0 -- wget -qO- http://localhost:3100/ready
# "ready" と返ってくれば OK
```

**3. Grafana の Tempo データソース設定確認**
- Grafana UI → Connections → Data sources → Tempo
- URL: `http://tempo.tracing.svc.cluster.local:3100`
- Save & Test で `Data source is working` になるか確認
