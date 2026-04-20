# Velero ガイド

## Velero とは

Kubernetes クラスターのバックアップ・リストア・マイグレーションツール。
以下の2種類のバックアップに対応する:

| 種別 | 対象 | 仕組み |
|------|------|--------|
| リソースバックアップ | Deployment, ConfigMap, Secret 等の k8s オブジェクト | etcd から取得 → S3 に保存 |
| ボリュームバックアップ | PVC のデータ | File System Backup (FSB) で Pod 内からコピー |

## homelab での構成

```
┌─────────────────────────────────────────────┐
│  Kubernetes クラスター                       │
│                                             │
│  ┌─────────┐  バックアップ  ┌──────────┐    │
│  │ velero  │ ──────────► │  MinIO   │    │
│  │  Pod    │              │ (S3互換) │    │
│  └─────────┘              └──────────┘    │
│       ↑                        ↑           │
│  Schedule CRD              Longhorn PVC    │
│  (毎日 02:00 JST)                          │
└─────────────────────────────────────────────┘
```

## バックアップの仕組み

### リソースバックアップ

1. Velero が Kubernetes API から全リソースの YAML を取得
2. gzip 圧縮して MinIO の `velero-backups/` に保存
3. バックアップのメタデータを `BackupStorageLocation` に登録

### ボリュームバックアップ (FSB)

`defaultVolumesToFsBackup: true` が設定されているため、PVC も自動でバックアップされる。

1. Velero が各 Pod にサイドカーとして `node-agent` を配置 (DaemonSet)
2. `node-agent` が Pod のファイルシステムを直接読み取りバックアップ
3. MinIO に保存

> Longhorn のスナップショットを使う方式 (CSI スナップショット) より互換性が高い。

## リストアの仕組み

```
バックアップ (MinIO)
    │
    ↓  velero restore create
k8s リソースの再作成 → PVC 作成 → データ復元
```

namespace ごと、または特定リソースのみリストア可能:

```bash
# namespace 単位でリストア
velero restore create --from-backup daily-backup --include-namespaces monitoring

# 特定リソースのみ
velero restore create --from-backup daily-backup \
  --include-resources deployments,services
```

## ArgoCD との共存

Velero でリストアしたリソースは ArgoCD の管理外になる場合がある。
リストア後は ArgoCD の sync を実行して状態を同期する:

```
argocd app sync <app-name>
```

## CRD 管理方針 (ArgoCD 管理下)

通常の Helm インストールでは `upgradeCRDs: true` (デフォルト) で
PreSync フックが bitnami/kubectl イメージで CRD をインストールする。

ArgoCD 管理下では ArgoCD 自身が `ServerSideApply` で CRD を管理するため
`upgradeCRDs: false` にする。これにより:

- 不要な init container が起動しない
- 壊れたイメージタグによる起動失敗を回避
- CRD の管理が ArgoCD に一元化される

---

## ファイル構成と各ファイルのコード解説

### ファイル一覧

| ファイル | 役割 |
|---------|------|
| `values-velero.yaml` | Velero Helm チャートのカスタム values ファイル。バックアップ先・スケジュール・プラグイン等の全設定を記述 |
| `README.md` | 運用手順書。デプロイ方法・バックアップ確認・リストア手順・トラブルシューティング |
| `GUIDE.md` | 本ファイル。Velero の概念説明・学習用ドキュメント |

### values-velero.yaml の全設定解説

このファイルは Velero Helm チャート (`vmware-tanzu/velero`) に渡すカスタム設定ファイル。
ArgoCD が Helm テンプレートを展開する際にこの values が使われ、Velero の動作を決定する。

---

#### upgradeCRDs: CRD アップグレードの無効化

```yaml
upgradeCRDs: false
```

**何をしているか:**
Velero の Helm チャートはデフォルトで `upgradeCRDs: true` になっており、デプロイ時に `bitnami/kubectl` イメージを使った init container (PreSync Job) が CRD を kubectl apply する。

**なぜ false にするか:**
- ArgoCD が `ServerSideApply` で CRD を管理しているため、二重管理を避ける
- `bitnami/kubectl` イメージが存在しないタグ (例: `1.34`) を参照して起動失敗するケースがある
- ArgoCD に CRD 管理を一元化することで、drift (状態のズレ) を検知しやすくなる

---

#### initContainers: AWS プラグインのインストール

```yaml
initContainers:
  - name: velero-plugin-for-aws
    image: velero/velero-plugin-for-aws:v1.9.0
    imagePullPolicy: IfNotPresent
    volumeMounts:
      - mountPath: /target
        name: plugins
```

**何をしているか:**
Velero 本体の Pod が起動する前に、init container として AWS プラグインのバイナリをプラグインディレクトリにコピーする。

**詳細:**
- `velero/velero-plugin-for-aws` は S3 互換ストレージ (MinIO を含む) との通信を担当するプラグイン
- init container が `/target` にバイナリをコピーし、メインの Velero コンテナがそれを読み込む
- `plugins` という名前の emptyDir ボリュームを共有することで、init container → メインコンテナへプラグインを受け渡す
- `imagePullPolicy: IfNotPresent` はローカルにイメージがあれば再ダウンロードしない設定 (ネットワーク帯域の節約)

**なぜ AWS プラグインなのか:**
MinIO は AWS S3 の API を完全互換で実装している。そのため、Velero からは「S3 と同じプロトコル」でアクセスでき、AWS 用プラグインがそのまま使える。

---

#### configuration.backupStorageLocation: バックアップ保存先

```yaml
configuration:
  backupStorageLocation:
    - name: default
      provider: aws
      bucket: velero-backups
      default: true
      config:
        region: minio
        s3ForcePathStyle: "true"
        s3Url: http://minio.minio.svc.cluster.local:9000
        publicUrl: http://minio-api.homelab.local
```

**何をしているか:**
Velero がバックアップデータを保存する先 (BackupStorageLocation = BSL) を定義する。

**各フィールドの解説:**

| フィールド | 値 | 説明 |
|-----------|-----|------|
| `name` | `default` | BSL の識別名。Schedule から参照される |
| `provider` | `aws` | 使用するプラグイン名 (S3 互換 = aws) |
| `bucket` | `velero-backups` | MinIO 上のバケット名。事前に MinIO Console で作成しておく必要がある |
| `default` | `true` | デフォルトの BSL として使用する。バックアップ作成時に明示指定しない場合はこれが使われる |
| `config.region` | `minio` | S3 リージョン。MinIO では任意の文字列で OK (AWS S3 では `ap-northeast-1` 等) |
| `config.s3ForcePathStyle` | `"true"` | パススタイル URL を強制する。MinIO は仮想ホストスタイル (`bucket.endpoint`) に対応しないため必須 |
| `config.s3Url` | `http://minio.minio.svc.cluster.local:9000` | クラスター内部から MinIO API にアクセスする URL。`minio` namespace の `minio` Service、ポート 9000 |
| `config.publicUrl` | `http://minio-api.homelab.local` | 外部 (ブラウザ等) からバックアップをダウンロードする際の URL。`velero backup download` で使われる |

**パススタイル vs 仮想ホストスタイルの違い:**
- パススタイル: `http://minio:9000/velero-backups/backup.tar.gz`
- 仮想ホストスタイル: `http://velero-backups.minio:9000/backup.tar.gz`

MinIO はパススタイルのみサポートするため、`s3ForcePathStyle: "true"` が必須。

---

#### configuration.volumeSnapshotLocation: ボリュームスナップショット保存先

```yaml
  volumeSnapshotLocation:
    - name: default
      provider: aws
      config:
        region: minio
```

**何をしているか:**
CSI スナップショットベースのボリュームバックアップを行う際の保存先を定義する。

**補足:**
この homelab では `defaultVolumesToFsBackup: true` が設定されているため、実際のボリュームバックアップは FSB (File System Backup) 方式で行われる。VolumeSnapshotLocation は Velero が起動時に必須として要求するため定義しているが、日常的なバックアップでは FSB が優先される。

---

#### credentials: MinIO 認証情報

```yaml
credentials:
  useSecret: true
  secretContents:
    cloud: |
      [default]
      aws_access_key_id = admin
      aws_secret_access_key = Minio12345
```

**何をしているか:**
Velero が MinIO にアクセスするための認証情報を Kubernetes Secret として作成する。

**詳細:**
- `useSecret: true` で Helm チャートが自動的に Secret リソースを生成する
- `secretContents.cloud` の内容は AWS CLI の credentials ファイル形式 (`~/.aws/credentials` と同じ)
- `[default]` はプロファイル名。Velero はデフォルトプロファイルを使用する
- `aws_access_key_id` / `aws_secret_access_key` は MinIO のアクセスキー (MinIO Console の `admin` / `Minio12345`)

**セキュリティ上の注意:**
本来、認証情報は Vault や ExternalSecrets で管理すべきだが、homelab 環境のため values ファイルに直接記載している。本番環境では Secret を外部シークレット管理に移行する。

---

#### schedules: バックアップスケジュール

```yaml
schedules:
  daily-backup:
    disabled: false
    schedule: "0 17 * * *"
    template:
      ttl: "168h"
      includedNamespaces:
        - "*"
      excludedNamespaces:
        - kube-system
        - kube-public
        - kube-node-lease
      storageLocation: default
      volumeSnapshotLocations:
        - default
```

**何をしているか:**
Velero の `Schedule` CRD を作成し、定期的に自動バックアップを実行する。

**各フィールドの解説:**

| フィールド | 値 | 説明 |
|-----------|-----|------|
| `daily-backup` | — | スケジュール名。`velero-daily-backup` という名前の Schedule CRD が作成される |
| `disabled` | `false` | スケジュールが有効 (true にすると一時停止) |
| `schedule` | `"0 17 * * *"` | cron 式。UTC 17:00 = JST 02:00 に毎日実行 |
| `template.ttl` | `"168h"` | バックアップの保持期間。168 時間 = 7 日間。期限切れバックアップは自動削除される |
| `template.includedNamespaces` | `["*"]` | バックアップ対象の namespace。`*` は全 namespace |
| `template.excludedNamespaces` | (下記参照) | バックアップから除外する namespace |
| `template.storageLocation` | `default` | 使用する BSL の名前 |
| `template.volumeSnapshotLocations` | `["default"]` | 使用する VSL の名前 |

**cron 式 `"0 17 * * *"` の読み方:**

```
┌───── 分 (0)
│ ┌───── 時 (17 = UTC 17時 = JST 翌2時)
│ │ ┌───── 日 (毎日)
│ │ │ ┌───── 月 (毎月)
│ │ │ │ ┌───── 曜日 (毎曜日)
0 17 * * *
```

**除外 namespace の理由:**

| namespace | 除外理由 |
|-----------|---------|
| `kube-system` | Kubernetes コアコンポーネント (kube-proxy, CoreDNS 等)。クラスター再構築時に自動生成されるため不要 |
| `kube-public` | クラスター情報の公開用 namespace。バックアップ不要 |
| `kube-node-lease` | ノードのハートビート情報。一時的データのため不要 |

**TTL (Time To Live) の仕組み:**
- 168h = 7 日間。バックアップ作成から 168 時間後に自動削除される
- 7 日分のバックアップが常にローテーションされる
- MinIO のストレージ容量を無限に消費しないための設定

---

#### resources: リソース制限

```yaml
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi
```

**何をしているか:**
Velero Pod の CPU / メモリのリソース要求と上限を設定する。

**詳細:**
- `requests`: Kubernetes スケジューラがノードに Pod を配置する際に確保するリソース量
- `limits`: Pod が使用できるリソースの上限。超えると OOMKill (メモリ) やスロットリング (CPU) される
- homelab のリソースが限られているため控えめな値に設定されている

---

#### defaultVolumesToFsBackup: FSB の有効化

```yaml
defaultVolumesToFsBackup: true
```

**何をしているか:**
全ての PVC を自動的に File System Backup (FSB) 方式でバックアップする。

**FSB とは:**
- 各ノードに DaemonSet として `node-agent` Pod が配置される
- `node-agent` が各 Pod のボリュームマウントを直接読み取り、ファイルレベルでバックアップ
- CSI スナップショットに対応していない環境でも PVC のバックアップが可能
- Longhorn のスナップショット機能に依存しないため、移植性が高い

**true の場合の動作:**
- Pod にアノテーション `backup.velero.io/backup-volumes` を明示しなくても、全 PVC が自動バックアップ対象になる
- 特定の PVC を除外したい場合は `backup.velero.io/backup-volumes-excludes` アノテーションを使う

---

#### metrics: Prometheus メトリクス連携

```yaml
metrics:
  enabled: true
  serviceMonitor:
    enabled: true
    additionalLabels:
      release: monitoring
```

**何をしているか:**
Velero のメトリクスを Prometheus で収集できるようにする。

**詳細:**
- `metrics.enabled: true`: Velero Pod がメトリクスエンドポイント (`:8085/metrics`) を公開する
- `serviceMonitor.enabled: true`: Prometheus Operator の `ServiceMonitor` CRD を自動作成する
- `additionalLabels.release: monitoring`: kube-prometheus-stack がこの ServiceMonitor を発見するためのラベル

**ServiceMonitor の仕組み:**
Prometheus Operator は `release: monitoring` ラベルが付いた ServiceMonitor を自動検出し、対象 Pod からメトリクスをスクレイプ (定期取得) する。これにより Grafana で以下のようなメトリクスを可視化できる:

- バックアップの成功/失敗回数
- バックアップの所要時間
- リストアの成功/失敗回数
- BackupStorageLocation の可用性
