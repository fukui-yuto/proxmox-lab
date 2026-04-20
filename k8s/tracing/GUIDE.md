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

---

## ファイル構成と各ファイルのコード解説

### ファイル構成一覧

| ファイル名 | 役割 |
|-----------|------|
| `namespace.yaml` | トレーシング関連リソースを配置する Kubernetes Namespace の定義 |
| `values-tempo.yaml` | Grafana Tempo (トレースストレージ) の Helm values 設定 |
| `values-otel-collector.yaml` | OpenTelemetry Collector (トレース受信・転送プロキシ) の Helm values 設定 |

この 3 ファイルで「トレースの受信 → 保存」パイプライン全体を構成している。
ArgoCD がこれらのファイルを参照して Helm Chart をデプロイする。

---

### namespace.yaml

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: tracing
```

**解説:**

Kubernetes の **Namespace** はリソースをグループ化する仕組み。
このファイルは `tracing` という名前の Namespace を作成する。

- `apiVersion: v1` -- Namespace は Kubernetes のコア API に含まれるため `v1` を指定する。
- `kind: Namespace` -- 作成するリソースの種類。ここでは Namespace を宣言している。
- `metadata.name: tracing` -- Namespace の名前。Tempo と OTel Collector の Pod やサービスはすべてこの Namespace 内に配置される。

Namespace を分けることで、トレーシング関連のリソースが他のアプリ (monitoring, logging など) と混ざらず、管理しやすくなる。
`kubectl get pods -n tracing` のように Namespace を指定して操作できる。

---

### values-tempo.yaml の全設定解説

```yaml
# Grafana Tempo Helm values
# ラボ向けシングルバイナリ構成

tempo:
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi

  retention: 24h

  storage:
    trace:
      backend: local
      local:
        path: /var/tempo/traces

persistence:
  enabled: true
  size: 10Gi
  storageClassName: longhorn
```

#### tempo.resources -- リソース制限

```yaml
tempo:
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
```

Kubernetes のリソース制限はコンテナが使える CPU とメモリの上限・下限を定義する。

| 設定 | 値 | 意味 |
|------|-----|------|
| `requests.cpu` | `100m` | 最低保証する CPU。`100m` = 0.1 コア (1000m = 1 コア)。スケジューラがノードに配置する際の基準 |
| `requests.memory` | `256Mi` | 最低保証するメモリ。256 MiB |
| `limits.cpu` | `500m` | CPU 使用量の上限。0.5 コアまでしか使えない |
| `limits.memory` | `512Mi` | メモリ使用量の上限。512 MiB を超えると OOMKilled (強制終了) される |

ホームラボではノードのリソースが限られている (NUC の i3 / 16GB) ため、各アプリに控えめなリソースを割り当てている。
Tempo はトレースの書き込み・読み取りを行うが、シングルバイナリ構成なので比較的軽量で動作する。

#### tempo.retention -- データ保持期間

```yaml
  retention: 24h
```

トレースデータを **24 時間** 保持する設定。24 時間を過ぎたトレースは自動的に削除される。

- ホームラボではディスク容量が限られるため、保持期間を短く設定している
- 本番環境では `72h` や `168h` (7 日) など、要件に応じて延長する
- 保持期間を長くするとディスク使用量が増えるので、`persistence.size` も合わせて調整が必要

#### tempo.storage -- ストレージバックエンド

```yaml
  storage:
    trace:
      backend: local
      local:
        path: /var/tempo/traces
```

トレースデータの保存先を指定する。

| 設定 | 値 | 意味 |
|------|-----|------|
| `backend` | `local` | ローカルファイルシステムに保存する。他の選択肢として `s3`, `gcs`, `azure` がある |
| `local.path` | `/var/tempo/traces` | コンテナ内のトレースデータ保存ディレクトリ |

Tempo は本来、S3 や GCS などのオブジェクトストレージに保存することで大規模運用に対応する。
しかしホームラボでは外部オブジェクトストレージを用意するのはオーバーなので、`local` (ローカルディスク) を使っている。
このパスは下記の PersistentVolume にマウントされるため、Pod が再起動してもデータは失われない。

#### persistence -- 永続ストレージ (PVC)

```yaml
persistence:
  enabled: true
  size: 10Gi
  storageClassName: longhorn
```

Kubernetes の **PersistentVolumeClaim (PVC)** を設定する。
PVC はコンテナのデータをディスクに永続化する仕組み。

| 設定 | 値 | 意味 |
|------|-----|------|
| `enabled` | `true` | PVC を有効化する。`false` にすると Pod 再起動時にデータが消える (EmptyDir) |
| `size` | `10Gi` | ディスク容量 10 GiB を確保する。24 時間分のトレースデータとしては十分な容量 |
| `storageClassName` | `longhorn` | Longhorn (分散ブロックストレージ) を使用する |

**Longhorn を使う理由:**
- Longhorn はこのラボの分散ストレージ基盤で、複数ノードにデータをレプリケーションする
- Tempo の Pod がどのノードに配置されてもデータにアクセスできる
- ノード障害時にもデータが失われない (レプリカが他のノードに存在する)

---

### values-otel-collector.yaml の全設定解説

```yaml
# OpenTelemetry Collector Helm values
# トレースを受信して Tempo に転送する

image:
  repository: otel/opentelemetry-collector-contrib

mode: deployment

resources:
  requests:
    cpu: 50m
    memory: 128Mi
  limits:
    cpu: 200m
    memory: 256Mi

config:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317
        http:
          endpoint: 0.0.0.0:4318
    jaeger:
      protocols:
        thrift_http:
          endpoint: 0.0.0.0:14268
        grpc:
          endpoint: 0.0.0.0:14250

  processors:
    batch: {}
    memory_limiter:
      limit_mib: 200
      spike_limit_mib: 50
      check_interval: 5s

  exporters:
    otlp:
      endpoint: tempo.tracing.svc.cluster.local:4317
      tls:
        insecure: true

  service:
    pipelines:
      traces:
        receivers: [otlp, jaeger]
        processors: [memory_limiter, batch]
        exporters: [otlp]
```

#### image -- コンテナイメージ

```yaml
image:
  repository: otel/opentelemetry-collector-contrib
```

使用するコンテナイメージを指定する。

- `otel/opentelemetry-collector-contrib` は **Contrib (拡張) 版**の Collector
- 通常版 (`otel/opentelemetry-collector`) は基本的な receiver/exporter のみ
- Contrib 版は Jaeger receiver など多数のプラグインが同梱されている
- このラボでは Jaeger プロトコルでの受信も行うため Contrib 版を使用している

#### mode -- デプロイモード

```yaml
mode: deployment
```

OpenTelemetry Collector の Kubernetes 上でのデプロイ方式を指定する。

| モード | 説明 | 用途 |
|--------|------|------|
| `deployment` | 通常の Deployment (レプリカ数指定可能) | トレースの集約・転送 (このラボの用途) |
| `daemonset` | 各ノードに 1 つずつ Pod を配置 | ノードレベルのメトリクス・ログ収集 |
| `statefulset` | 状態を持つ StatefulSet | テールサンプリングなど状態が必要な場合 |

このラボではトレースを受信して Tempo に転送するだけなので `deployment` で十分。
1 つの Pod がクラスター全体のトレースを処理する。

#### resources -- リソース制限

```yaml
resources:
  requests:
    cpu: 50m
    memory: 128Mi
  limits:
    cpu: 200m
    memory: 256Mi
```

| 設定 | 値 | 意味 |
|------|-----|------|
| `requests.cpu` | `50m` | 最低保証 CPU 0.05 コア。Collector はデータを中継するだけなので軽量 |
| `requests.memory` | `128Mi` | 最低保証メモリ 128 MiB |
| `limits.cpu` | `200m` | CPU 上限 0.2 コア |
| `limits.memory` | `256Mi` | メモリ上限 256 MiB。後述の `memory_limiter` と合わせて OOM を防止する |

Tempo よりもさらに軽量なリソース割り当て。Collector はデータを受け取ってバッチ処理し転送するだけなので、大量のメモリは不要。

#### config.receivers -- データ受信設定

```yaml
config:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317
        http:
          endpoint: 0.0.0.0:4318
    jaeger:
      protocols:
        thrift_http:
          endpoint: 0.0.0.0:14268
        grpc:
          endpoint: 0.0.0.0:14250
```

**Receiver** はテレメトリデータを受信するコンポーネント。ここでは 2 種類の receiver を設定している。

**OTLP Receiver (推奨):**

| プロトコル | ポート | 説明 |
|-----------|--------|------|
| gRPC | 4317 | OpenTelemetry 標準の gRPC プロトコル。高速で効率的。推奨 |
| HTTP | 4318 | OpenTelemetry 標準の HTTP プロトコル。gRPC が使えない環境向け |

- `endpoint: 0.0.0.0:4317` -- すべてのネットワークインターフェースでリッスンする (Pod 内からアクセス可能にするため)
- OTLP (OpenTelemetry Protocol) は OpenTelemetry の標準プロトコル。新しいアプリからはこちらを使う

**Jaeger Receiver (レガシー互換):**

| プロトコル | ポート | 説明 |
|-----------|--------|------|
| Thrift HTTP | 14268 | Jaeger クライアントの HTTP プロトコル |
| gRPC | 14250 | Jaeger クライアントの gRPC プロトコル |

- 既存の Jaeger SDK で計装されたアプリからトレースを受信するために用意している
- 新規のアプリは OTLP を使うべきだが、移行期間中の互換性のために Jaeger receiver も有効にしている

#### config.processors -- データ加工設定

```yaml
  processors:
    batch: {}
    memory_limiter:
      limit_mib: 200
      spike_limit_mib: 50
      check_interval: 5s
```

**Processor** は受信したデータを加工・制御するコンポーネント。

**batch プロセッサ:**

```yaml
    batch: {}
```

- 受信したトレースデータをまとめて (バッチで) Exporter に送信する
- `{}` はデフォルト設定を使う意味 (8192 件ごと、または 200ms ごとに送信)
- バッチ処理することで Tempo への書き込み回数を減らし、効率化する
- 1 件ずつ送信すると TCP 接続のオーバーヘッドが大きくなるため、バッチ処理は重要

**memory_limiter プロセッサ:**

```yaml
    memory_limiter:
      limit_mib: 200
      spike_limit_mib: 50
      check_interval: 5s
```

| 設定 | 値 | 意味 |
|------|-----|------|
| `limit_mib` | `200` | メモリ使用量のソフトリミット (200 MiB)。これを超えるとデータの受信を拒否する |
| `spike_limit_mib` | `50` | 急激なメモリ増加に対する追加マージン。`limit_mib - spike_limit_mib` = 150 MiB がバッファ |
| `check_interval` | `5s` | メモリ使用量を 5 秒ごとにチェックする |

- OOMKilled (メモリ不足によるコンテナ強制終了) を防ぐための安全装置
- `limits.memory: 256Mi` に対して `limit_mib: 200` を設定しているので、56 MiB の余裕がある
- トレースが大量に送信された場合、メモリが上限に近づくとデータの受信を一時停止する
- **pipeline 定義では `memory_limiter` を `batch` の前に配置する** (メモリチェックが先に行われるべきため)

#### config.exporters -- データ送信設定

```yaml
  exporters:
    otlp:
      endpoint: tempo.tracing.svc.cluster.local:4317
      tls:
        insecure: true
```

**Exporter** は処理済みデータを外部システムに送信するコンポーネント。

| 設定 | 値 | 意味 |
|------|-----|------|
| `endpoint` | `tempo.tracing.svc.cluster.local:4317` | Tempo の OTLP gRPC エンドポイント |
| `tls.insecure` | `true` | TLS を使わない (クラスター内部通信なので暗号化不要) |

- `tempo.tracing.svc.cluster.local` は Kubernetes の内部 DNS 名
  - `tempo` = Service 名
  - `tracing` = Namespace 名
  - `svc.cluster.local` = Kubernetes サービスのドメイン
- ポート `4317` は Tempo が OTLP gRPC で受信するポート
- `tls.insecure: true` はクラスター内部通信のため暗号化を省略している。外部通信では `false` にすべき

#### config.service.pipelines -- パイプライン定義

```yaml
  service:
    pipelines:
      traces:
        receivers: [otlp, jaeger]
        processors: [memory_limiter, batch]
        exporters: [otlp]
```

**Pipeline** は receiver → processor → exporter の処理の流れを定義する。

```
受信 (receivers)        加工 (processors)         送信 (exporters)
[otlp, jaeger]  →  [memory_limiter, batch]  →  [otlp (→ Tempo)]
```

- `receivers: [otlp, jaeger]` -- OTLP と Jaeger の両方のプロトコルで受信したトレースをこのパイプラインで処理する
- `processors: [memory_limiter, batch]` -- まずメモリ制限をチェックし、次にバッチ処理する (順序が重要)
- `exporters: [otlp]` -- 処理済みデータを OTLP プロトコルで Tempo に送信する

パイプラインは `traces` (トレース)、`metrics` (メトリクス)、`logs` (ログ) の 3 種類を定義できる。
このラボではトレースのみを扱うため `traces` パイプラインだけ定義している。

---

### トレースデータの流れ

以下は、アプリケーションからトレースデータが送信され、最終的に Grafana で可視化されるまでの全体の流れを示す。

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                         トレースデータの流れ                                │
│                                                                              │
│  ┌─────────┐     OTLP gRPC (:4317)     ┌──────────────────┐                │
│  │  アプリ  │ ──────────────────────────→│                  │                │
│  │ (Node.js │     OTLP HTTP (:4318)     │                  │                │
│  │  Python  │ ──────────────────────────→│   OTel Collector │                │
│  │  Go ...) │                           │                  │                │
│  └─────────┘     Jaeger gRPC (:14250)   │   [processors]   │                │
│  ┌─────────┐ ──────────────────────────→│   memory_limiter │                │
│  │  レガシー │    Jaeger HTTP (:14268)   │   batch          │                │
│  │  アプリ  │ ──────────────────────────→│                  │                │
│  └─────────┘                            └────────┬─────────┘                │
│                                                  │                          │
│                                    OTLP gRPC (:4317)                        │
│                                                  │                          │
│                                                  ▼                          │
│                                         ┌────────────────┐                  │
│                                         │                │                  │
│                                         │  Grafana Tempo │                  │
│                                         │                │                  │
│                                         │  [storage]     │                  │
│                                         │  local: 10Gi   │                  │
│                                         │  Longhorn PVC  │                  │
│                                         │  retention:24h │                  │
│                                         └────────┬───────┘                  │
│                                                  │                          │
│                                       TraceQL クエリ                        │
│                                                  │                          │
│                                                  ▼                          │
│                                         ┌────────────────┐                  │
│                                         │                │                  │
│                                         │    Grafana     │                  │
│                                         │   (Explore →   │                  │
│                                         │    Tempo)      │                  │
│                                         │                │                  │
│                                         └────────────────┘                  │
│                                                  │                          │
│                                                  ▼                          │
│                                           ブラウザで                        │
│                                         トレースを可視化                    │
└──────────────────────────────────────────────────────────────────────────────┘
```

**データフローの詳細:**

1. **アプリ → OTel Collector:** アプリケーションが OpenTelemetry SDK を使ってトレースデータを送信する。送信先は `otel-collector.tracing.svc.cluster.local` のポート 4317 (gRPC) または 4318 (HTTP)。レガシーな Jaeger クライアントはポート 14250/14268 に送信する。

2. **OTel Collector (処理):** 受信したトレースデータに対して `memory_limiter` でメモリ使用量をチェックし、`batch` プロセッサでまとめてから次のステップに渡す。

3. **OTel Collector → Tempo:** 処理済みのトレースデータを OTLP gRPC プロトコルで `tempo.tracing.svc.cluster.local:4317` に転送する。クラスター内部通信なので TLS は使わない。

4. **Tempo (保存):** 受信したトレースを Longhorn PVC 上のローカルファイルシステム (`/var/tempo/traces`) に保存する。24 時間経過したデータは自動削除される。

5. **Grafana → Tempo (クエリ):** ユーザーが Grafana の Explore 画面で Tempo データソースを選択し、TraceQL でクエリを実行すると、Grafana が Tempo に問い合わせてトレースデータを取得する。

6. **Grafana → ブラウザ:** 取得したトレースデータをウォーターフォールチャートやサービスグラフとして可視化し、ブラウザに表示する。
