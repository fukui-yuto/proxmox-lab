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
    "host": "k3s-worker03"
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

---

## ファイル構成と各ファイルのコード解説

### ファイル構成一覧

| ファイル | 種別 | 役割 |
|---------|------|------|
| `namespace.yaml` | Kubernetes マニフェスト | logging 名前空間の作成 |
| `values-elasticsearch.yaml` | Helm values | Elasticsearch Helm chart のカスタム設定 |
| `values-fluent-bit.yaml` | Helm values | Fluent Bit Helm chart のカスタム設定 |
| `values-kibana.yaml` | Helm values | Kibana Helm chart のカスタム設定 (未使用・参考用) |
| `kibana.yaml` | Kubernetes マニフェスト | Kibana の Deployment + Service (直接管理) |
| `kibana-ingress.yaml` | Kubernetes マニフェスト | Kibana への外部アクセス (oauth2-proxy 経由) |
| `elasticsearch-ingress.yaml` | Kubernetes マニフェスト | Elasticsearch への外部アクセス (直接) |
| `oauth2-proxy.yaml` | Kubernetes マニフェスト | Keycloak SSO による Kibana 認証プロキシ |

---

### namespace.yaml

```yaml
apiVersion: v1        # Kubernetes コア API
kind: Namespace       # リソースの種類: 名前空間
metadata:
  name: logging       # 名前空間名 — logging スタック全体をこの中に配置
```

**解説:**

- Kubernetes では Namespace を使ってリソースを論理的に分離する
- `logging` という名前空間を作成し、Elasticsearch / Fluent Bit / Kibana / oauth2-proxy を全てこの中にデプロイする
- 名前空間を分けることで、他のアプリ (monitoring, vault 等) とリソースが混ざらず管理しやすくなる
- `kubectl get pods -n logging` のように `-n logging` を付けてこの名前空間のリソースを操作する

---

### values-elasticsearch.yaml (Elasticsearch Helm values)

このファイルは Elasticsearch の公式 Helm chart に渡すカスタム設定値。
ラボ環境 (シングルノード・リソース制限あり) に最適化されている。

```yaml
# ===== レプリカ数 =====
replicas: 1               # Elasticsearch の Pod 数を 1 に設定
minimumMasterNodes: 1     # マスターノードの最小数 (クォーラム)
# 理由: ホームラボはリソースが限られるためシングルノード構成。
# 本番環境では最低 3 ノード (replicas: 3, minimumMasterNodes: 2) が推奨される。
# シングルノードではシャードレプリカを配置できないため、クラスター状態は yellow になる。

# ===== セキュリティ・TLS 無効化 =====
protocol: http            # HTTPS ではなく HTTP を使用
createCert: false         # TLS 証明書を自動生成しない
# 理由: Elasticsearch 8.x からデフォルトで TLS + セキュリティが有効になった。
# ラボ環境では内部ネットワークのみで運用するため、オーバーヘッドを避けて無効化する。
# Fluent Bit → Elasticsearch 間の通信も HTTP で行うため、ここを http にしないと接続できない。

# ===== Elasticsearch 設定ファイル (elasticsearch.yml) =====
esConfig:
  elasticsearch.yml: |
    xpack.security.enabled: false
    # → X-Pack セキュリティ機能を完全に無効化。
    #   これにより認証なしで Elasticsearch API にアクセスできる。
    #   有効のままだとユーザー名/パスワード認証が必要になる。

    xpack.security.enrollment.enabled: false
    # → ノード間の自動登録 (enrollment) を無効化。
    #   マルチノード構成でノードが自動的にクラスターに参加する機能だが、
    #   シングルノードでは不要。

    xpack.security.http.ssl.enabled: false
    # → HTTP API (ポート 9200) の TLS を無効化。
    #   Fluent Bit や Kibana が http:// でアクセスするために必要。

    xpack.security.transport.ssl.enabled: false
    # → ノード間通信 (ポート 9300) の TLS を無効化。
    #   シングルノードなのでノード間通信は発生しないが、明示的に無効化。

    # NOTE: discovery.type: single-node はここに設定できない。
    # Helm chart が StatefulSet の env var で cluster.initial_master_nodes を
    # 自動設定するため、discovery.type: single-node と共存できず ES が起動不能に
    # なる (IllegalArgumentException)。

# ===== リソース制限 =====
resources:
  requests:
    cpu: 100m             # 最低限確保する CPU (0.1 コア)
    memory: 512Mi         # 最低限確保するメモリ (512MB)
  limits:
    cpu: 1000m            # CPU の上限 (1 コア)
    memory: 1.5Gi         # メモリの上限 (1.5GB)
# 理由: ラボのワーカーノードは RAM 4〜8GB しかない。
# Elasticsearch はメモリを大量に消費するため、上限を設けて他の Pod を圧迫しないようにする。

# ===== JVM ヒープサイズ =====
esJavaOpts: "-Xmx512m -Xms512m"
# -Xmx512m: JVM ヒープの最大サイズ = 512MB
# -Xms512m: JVM ヒープの初期サイズ = 512MB (最初から確保)
# 理由: Elasticsearch は Java で動いており、JVM ヒープの設定が重要。
# 一般的なベストプラクティス: メモリ limit の約 50% をヒープに割り当てる。
# 残りの 50% は Lucene のファイルキャッシュ (OS ページキャッシュ) に使われる。
# 1.5Gi limit × 50% ≈ 750MB だが、余裕を持って 512MB に設定。

# ===== 永続ボリューム (PVC) =====
volumeClaimTemplate:
  accessModes: ["ReadWriteOnce"]    # 単一 Pod からの読み書き
  storageClassName: longhorn         # Longhorn 分散ストレージを使用
  resources:
    requests:
      storage: 10Gi                  # 10GB のディスクを確保
# 理由: Elasticsearch のデータ (インデックス) を永続化する。
# Pod が再起動してもデータが消えない。
# Longhorn を使うことで、ノード障害時にもデータが別ノードにレプリケートされる。

persistence:
  enabled: true    # 永続化を有効にする (デフォルトは emptyDir で Pod 再起動でデータ消失)

# ===== Service 設定 =====
service:
  type: ClusterIP   # クラスター内部からのみアクセス可能
  port: 9200        # Elasticsearch の HTTP API ポート

# ===== スケジューリング制約 =====
antiAffinity: "soft"
# → 同じノードに複数の Elasticsearch Pod をなるべく配置しない (soft = best-effort)。
# replicas: 1 なので実質無意味だが、将来スケールアウト時のために設定。

nodeAffinity:
  requiredDuringSchedulingIgnoredDuringExecution:
    nodeSelectorTerms:
      - matchExpressions:
          - key: node-role.kubernetes.io/control-plane
            operator: DoesNotExist
# → コントロールプレーンノード (k3s-master) には絶対に配置しない。
# 理由: k3s-master は RAM 6GB しかなく NoSchedule taint が付いている。
# Elasticsearch のようなメモリ消費の大きいアプリを載せると API server が不安定になる。

# ===== Lifecycle Hook =====
lifecycle:
  postStart:
    exec:
      command:
        - bash
        - -c
        - "touch /tmp/.es_start_file"
# 解説: Elasticsearch Helm chart の readiness probe は以下のロジックで動作する:
#   1. /tmp/.es_start_file が存在しない → wait_for_status=green でヘルスチェック
#   2. /tmp/.es_start_file が存在する → 単に / が HTTP 200 を返すかチェック
#
# シングルノード構成ではレプリカシャードを配置できず、クラスター状態は必ず yellow になる。
# green を待ち続けると readiness probe が永遠に失敗し、Pod が Ready にならない。
# postStart で即座にファイルを作成することで、green チェックをスキップし、
# 「Elasticsearch が HTTP 応答を返せるか」だけで Ready 判定させる。
```

---

### values-fluent-bit.yaml (Fluent Bit Helm values)

このファイルは Fluent Bit の公式 Helm chart に渡すカスタム設定値。
ログ収集のパイプライン (INPUT → FILTER → OUTPUT) を定義する。

```yaml
# ===== リソース制限 =====
resources:
  requests:
    cpu: 50m              # 0.05 コア (非常に軽量)
    memory: 64Mi          # 64MB
  limits:
    cpu: 100m             # 0.1 コア
    memory: 128Mi         # 128MB
# Fluent Bit は C 言語で書かれた軽量エージェント。
# Fluentd (Ruby) と比べてメモリ消費が 1/10 以下。
# DaemonSet として全ノードに配置されるため、リソースを抑えることが重要。

config:
  # ===== INPUT セクション: ログの収集元 =====
  inputs: |
    [INPUT]
        Name              tail
        # → "tail" プラグインを使用。ファイルの末尾を追跡して新しいログ行を読み取る。
        #   Linux の `tail -f` と同じ概念。

        Path              /var/log/containers/*.log
        # → 収集対象のファイルパス (ワイルドカード)。
        #   Kubernetes は全コンテナのログをこのディレクトリに保存する。
        #   ファイル名の例: /var/log/containers/nginx-abc123_default_nginx-xyz.log

        multiline.parser  docker, cri
        # → マルチラインパーサー。複数行にまたがるログ (スタックトレース等) を1つのレコードに結合。
        #   docker: Docker ランタイムのログ形式
        #   cri: containerd / CRI-O のログ形式 (k3s はこちらを使用)

        Tag               kube.*
        # → このINPUTから来たログに "kube.*" というタグを付ける。
        #   FILTER や OUTPUT の Match で使い、どのログをどこに送るか制御する。

        Mem_Buf_Limit     5MB
        # → メモリバッファの上限。Elasticsearch が一時的にダウンした場合、
        #   ここにログを溜めておく。5MB を超えると古いログを破棄する (バックプレッシャー)。

        Skip_Long_Lines   On
        # → 非常に長い行 (バイナリデータの混入など) をスキップする。
        #   これがないとパース失敗でログ収集が止まる可能性がある。

  # ===== FILTER セクション: ログの加工・メタデータ付与 =====
  filters: |
    [FILTER]
        Name                kubernetes
        # → "kubernetes" フィルタープラグイン。
        #   ログファイル名から Pod 名を特定し、Kubernetes API に問い合わせて
        #   メタデータ (namespace, labels, annotations 等) を付与する。

        Match               kube.*
        # → INPUT で "kube.*" タグが付いたログだけを処理対象にする。

        Kube_URL            https://kubernetes.default.svc:443
        # → Kubernetes API サーバーのエンドポイント。
        #   クラスター内部の DNS 名で指定。

        Kube_CA_File        /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
        # → API サーバーの TLS 証明書を検証するための CA 証明書。
        #   ServiceAccount が自動マウントするファイル。

        Kube_Token_File     /var/run/secrets/kubernetes.io/serviceaccount/token
        # → API サーバーへの認証トークン。
        #   ServiceAccount が自動マウントするファイル。

        Kube_Tag_Prefix     kube.var.log.containers.
        # → タグからファイルパスを抽出するためのプレフィックス。
        #   タグ "kube.var.log.containers.nginx-abc_default_nginx-xyz.log" から
        #   "nginx-abc_default_nginx-xyz.log" を抽出して Pod 情報を特定する。

        Merge_Log           On
        # → ログ本文が JSON の場合、パースして各フィールドをトップレベルに展開する。
        #   例: {"level":"error","msg":"timeout"} → level, msg フィールドが追加される。

        Keep_Log            Off
        # → Merge_Log でパース成功した場合、元の "log" フィールドを削除する。
        #   重複を避けてストレージを節約する。

        K8S-Logging.Parser  On
        # → Pod の annotation (fluentbit.io/parser) で個別のパーサーを指定可能にする。

        K8S-Logging.Exclude On
        # → Pod の annotation (fluentbit.io/exclude: "true") でログ収集を除外可能にする。
        #   大量のログを出す Pod を個別にスキップできる。

  # ===== OUTPUT セクション: ログの転送先 =====
  outputs: |
    [OUTPUT]
        Name                es
        # → "es" (Elasticsearch) 出力プラグインを使用。

        Match               kube.*
        # → "kube.*" タグのログを Elasticsearch に送信する。

        Host                elasticsearch-master.logging.svc.cluster.local
        # → Elasticsearch の Service DNS 名。
        #   <サービス名>.<名前空間>.svc.cluster.local の形式。

        Port                9200
        # → Elasticsearch の HTTP API ポート。

        Logstash_Format     On
        # → インデックス名を Logstash 形式 (日付ローテーション) にする。
        #   例: fluent-bit-2024.01.15, fluent-bit-2024.01.16 ...
        #   日ごとにインデックスが作られるため、古いログの削除が容易。

        Logstash_Prefix     fluent-bit
        # → インデックス名のプレフィックス。fluent-bit-YYYY.MM.DD になる。

        Replace_Dots        On
        # → フィールド名のドット (.) をアンダースコア (_) に置換する。
        #   Elasticsearch はフィールド名にドットがあるとネストされたオブジェクトと
        #   解釈してマッピング衝突が起きるため。

        Retry_Limit         False
        # → リトライ回数を無制限にする。
        #   Elasticsearch が一時的にダウンしても諦めずに再送し続ける。

        tls                 Off
        # → TLS を使わない (HTTP 接続)。
        #   Elasticsearch 側で TLS を無効化しているため合わせる。

        tls.verify          Off
        # → TLS 証明書の検証をスキップ (TLS Off なので実質無意味だが明示)。

        Suppress_Type_Name  On
        # → Elasticsearch 8.x では _type フィールドが廃止された。
        #   これを On にしないと 8.x に書き込み時にエラーになる。
```

---

### kibana.yaml (Kibana Deployment + Service)

Kibana を直接 Kubernetes マニフェストでデプロイする。
(Helm chart の values-kibana.yaml は参考用として残しているが、実際にはこのマニフェストを使用)

```yaml
# ===== Deployment: Kibana アプリケーション =====
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kibana
  namespace: logging            # logging 名前空間に配置
spec:
  replicas: 1                   # 1 Pod のみ (ラボ環境)
  selector:
    matchLabels:
      app: kibana               # このラベルを持つ Pod を管理対象にする
  template:
    metadata:
      labels:
        app: kibana             # Service が Pod を発見するためのラベル
    spec:
      containers:
        - name: kibana
          image: docker.elastic.co/kibana/kibana:8.5.1
          # → Elastic 公式の Kibana 8.5.1 イメージ

          env:
            - name: ELASTICSEARCH_HOSTS
              value: "http://elasticsearch-master:9200"
              # → 接続先の Elasticsearch を指定。
              #   "elasticsearch-master" は Helm chart が作成する Service 名。
              #   同じ logging 名前空間内なのでサービス名だけで解決できる。

            - name: XPACK_SECURITY_ENABLED
              value: "false"
              # → Kibana 側でもセキュリティを無効化。
              #   Elasticsearch のセキュリティが無効なので合わせる。

          ports:
            - containerPort: 5601    # Kibana の Web UI ポート

          resources:
            requests:
              cpu: 200m              # 0.2 コア
              memory: 512Mi          # 512MB
            limits:
              cpu: 500m              # 0.5 コア
              memory: 1Gi            # 1GB
            # Kibana は Node.js アプリケーションで起動時にメモリを多く消費する。

          readinessProbe:
            httpGet:
              path: /api/status      # Kibana のステータス API
              port: 5601
            initialDelaySeconds: 60  # 起動後 60 秒待ってからチェック開始
            periodSeconds: 10        # 10 秒ごとにチェック
            failureThreshold: 10     # 10 回連続失敗で Not Ready
            # 理由: Kibana は起動に 1〜2 分かかることがある。
            # 短い initialDelaySeconds だと起動中に何度も再起動されてしまう。

---
# ===== Service: クラスター内部での接続ポイント =====
apiVersion: v1
kind: Service
metadata:
  name: kibana
  namespace: logging
spec:
  selector:
    app: kibana                  # app: kibana ラベルの Pod にルーティング
  ports:
    - port: 5601                 # Service が公開するポート
      targetPort: 5601           # Pod の実際のポート
  # type 省略時は ClusterIP (クラスター内部からのみアクセス可能)
```

---

### kibana-ingress.yaml (Kibana Ingress — oauth2-proxy 経由の SSO)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: kibana
  namespace: logging
spec:
  ingressClassName: traefik       # Traefik Ingress Controller を使用
  rules:
    - host: kibana.homelab.local  # このホスト名でアクセスされたリクエストを処理
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: oauth2-proxy    # ← kibana ではなく oauth2-proxy に送る!
                port:
                  number: 4180
```

**解説:**

- 通常の Ingress は backend に Kibana の Service を直接指定するが、ここでは `oauth2-proxy` を経由させている
- これにより、Kibana にアクセスする前に必ず Keycloak で認証が必要になる
- 認証フロー:
  1. ユーザーが `http://kibana.homelab.local` にアクセス
  2. Traefik が Ingress ルールに従い oauth2-proxy にルーティング
  3. oauth2-proxy が未認証を検知 → Keycloak のログイン画面にリダイレクト
  4. ユーザーが Keycloak で認証成功
  5. oauth2-proxy が認証済みリクエストを upstream (Kibana) に転送

---

### elasticsearch-ingress.yaml (Elasticsearch Ingress — 直接アクセス)

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: elasticsearch
  namespace: logging
spec:
  ingressClassName: traefik
  rules:
    - host: elasticsearch.homelab.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: elasticsearch-master   # Helm chart が作成する Service 名
                port:
                  number: 9200
```

**解説:**

- Elasticsearch API に外部から直接アクセスするための Ingress
- oauth2-proxy を経由していない (認証なし)
- 理由: Elasticsearch API はプログラムから直接クエリを投げる用途 (Grafana データソース、スクリプト等) で使うため
- セキュリティは xpack.security を無効化しているため、ラボ内 LAN からのアクセスを前提としている
- `elasticsearch-master` は Elasticsearch Helm chart がデフォルトで作成する Service 名

---

### oauth2-proxy.yaml (Keycloak OIDC 認証プロキシ)

```yaml
# ===== Deployment: oauth2-proxy =====
apiVersion: apps/v1
kind: Deployment
metadata:
  name: oauth2-proxy
  namespace: logging
  labels:
    app: oauth2-proxy
spec:
  replicas: 1
  selector:
    matchLabels:
      app: oauth2-proxy
  template:
    metadata:
      labels:
        app: oauth2-proxy
    spec:
      containers:
        - name: oauth2-proxy
          image: quay.io/oauth2-proxy/oauth2-proxy:v7.6.0
          # → oauth2-proxy の公式イメージ。リバースプロキシとして動作し、
          #   未認証ユーザーを OIDC プロバイダー (Keycloak) にリダイレクトする。

          args:
            - --provider=keycloak-oidc
            # → 認証プロバイダーとして Keycloak (OIDC) を使用。
            #   Keycloak 固有のトークンエンドポイント・ユーザー情報取得に対応。

            - --client-id=kibana
            # → Keycloak に登録した OIDC クライアントの ID。
            #   Keycloak 管理画面で "kibana" というクライアントを事前に作成しておく。

            - --client-secret=kibana-keycloak-secret-2026
            # → クライアントシークレット (Keycloak で生成)。
            #   oauth2-proxy が Keycloak にトークン交換を要求する際に使用。

            - --oidc-issuer-url=http://keycloak.homelab.local/realms/homelab
            # → OIDC の Issuer URL。Keycloak の "homelab" レルムを指定。
            #   oauth2-proxy はこの URL から .well-known/openid-configuration を取得し、
            #   認可エンドポイント・トークンエンドポイントを自動発見する。

            - --cookie-secret=aG9tZWxhYi1raWJhbmEtb2F1dGgyLXNlY3JldGtleXM=
            # → セッション Cookie の暗号化キー (Base64 エンコード)。
            #   ユーザーの認証状態を Cookie に保存する際の暗号化に使う。

            - --cookie-secure=false
            # → Cookie に Secure フラグを付けない (HTTP で動作させるため)。
            #   HTTPS を使わないラボ環境では false にしないと Cookie が送信されない。

            - --http-address=0.0.0.0:4180
            # → oauth2-proxy がリッスンするアドレスとポート。

            - --upstream=http://kibana:5601
            # → 認証成功後にリクエストを転送する先 (= Kibana)。
            #   同じ名前空間の kibana Service にプロキシする。

            - --email-domain=*
            # → メールドメインの制限なし (全てのメールアドレスを許可)。
            #   Keycloak 側でアクセス制御するためここでは制限しない。

            - --scope=openid profile email groups
            # → OIDC で要求するスコープ。
            #   openid: 必須 / profile: ユーザー名等 / email / groups: グループ情報

            - --redirect-url=http://kibana.homelab.local/oauth2/callback
            # → Keycloak での認証後にリダイレクトされる URL。
            #   Keycloak のクライアント設定で "Valid Redirect URIs" に登録が必要。

            - --skip-provider-button=true
            # → プロバイダー選択画面をスキップして直接 Keycloak に飛ばす。
            #   プロバイダーが 1 つしかないので選択画面は不要。

            - --code-challenge-method=S256
            # → PKCE (Proof Key for Code Exchange) を使用。
            #   認可コード横取り攻撃を防ぐセキュリティ強化。

            - --insecure-oidc-allow-unverified-email=true
            # → メールアドレスが未検証のユーザーでもログインを許可。
            #   ラボ環境のため全ユーザーを許可する。

          ports:
            - containerPort: 4180
              name: http

          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi

          livenessProbe:
            httpGet:
              path: /ping       # oauth2-proxy の死活監視エンドポイント
              port: 4180
            initialDelaySeconds: 10

          readinessProbe:
            httpGet:
              path: /ping       # Ready 判定も /ping を使用
              port: 4180

---
# ===== Service: oauth2-proxy への接続ポイント =====
apiVersion: v1
kind: Service
metadata:
  name: oauth2-proxy
  namespace: logging
spec:
  selector:
    app: oauth2-proxy
  ports:
    - port: 4180
      targetPort: 4180
      name: http
  # Ingress (kibana-ingress.yaml) がこの Service にトラフィックを送る
```

---

### ログの流れ全体図

以下は、コンテナのログが最終的にユーザーの画面に表示されるまでの全体フロー。

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        k3s クラスター                                     │
│                                                                         │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │  各ワーカーノード (worker03〜08)                                    │   │
│  │                                                                    │   │
│  │  [Pod A] ─── stdout/stderr ───┐                                   │   │
│  │  [Pod B] ─── stdout/stderr ───┼──→ /var/log/containers/*.log      │   │
│  │  [Pod C] ─── stdout/stderr ───┘         ↓                         │   │
│  │                                    ┌──────────┐                    │   │
│  │                                    │Fluent Bit│ (DaemonSet)        │   │
│  │                                    │  INPUT   │ tail プラグイン      │   │
│  │                                    │  FILTER  │ k8s メタデータ付与   │   │
│  │                                    │  OUTPUT  │ es プラグイン        │   │
│  │                                    └────┬─────┘                    │   │
│  └─────────────────────────────────────────┼─────────────────────────┘   │
│                                            │ HTTP POST (JSON)            │
│                                            ▼                             │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │  logging Namespace                                                 │   │
│  │                                                                    │   │
│  │  ┌─────────────────────┐     ┌─────────┐     ┌──────────────┐    │   │
│  │  │  Elasticsearch      │     │  Kibana │     │ oauth2-proxy │    │   │
│  │  │  (StatefulSet)      │◀────│  :5601  │     │   :4180      │    │   │
│  │  │  :9200              │検索  └─────────┘     └──────┬───────┘    │   │
│  │  │                     │            ▲                 │            │   │
│  │  │  Index:             │            │ upstream        │            │   │
│  │  │  fluent-bit-YYYY.MM.DD          └─────────────────┘            │   │
│  │  └─────────────────────┘                                          │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                                            ▲                             │
└────────────────────────────────────────────┼─────────────────────────────┘
                                             │ Ingress (Traefik)
                                             │
                              ┌──────────────┴──────────────┐
                              │  ブラウザ                      │
                              │  http://kibana.homelab.local  │
                              │       ↓                       │
                              │  1. Keycloak でログイン        │
                              │  2. Kibana でログ検索          │
                              └─────────────────────────────┘
```

**ログ配送の詳細ステップ:**

```
1. コンテナが stdout/stderr に出力
       ↓
2. containerd (CRI) がログを /var/log/containers/<pod>_<ns>_<container>-<id>.log に書き込み
       ↓
3. Fluent Bit (DaemonSet) が tail プラグインでファイルを監視・読み取り
       ↓
4. kubernetes フィルターが Kubernetes API に問い合わせてメタデータを付与
   (pod_name, namespace_name, container_name, labels, annotations)
       ↓
5. es 出力プラグインが Elasticsearch に HTTP POST で送信
   (Logstash 形式: fluent-bit-2026.04.21 のような日付別インデックスに格納)
       ↓
6. Elasticsearch が転置インデックスを構築して全文検索可能にする
       ↓
7. ユーザーが Kibana (http://kibana.homelab.local) にアクセス
       ↓
8. oauth2-proxy が Keycloak で認証後、Kibana にプロキシ
       ↓
9. Kibana が Elasticsearch に検索クエリを発行して結果を表示
```
