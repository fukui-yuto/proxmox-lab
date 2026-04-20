# k8s 全体アーキテクチャ — サービス間の関係と依存構造

## 全体俯瞰図

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                          k3s クラスター (Proxmox 上)                                  │
│                                                                                     │
│  ┌─── Layer 0: ネットワーク基盤 ──────────────────────────────────────────────────┐   │
│  │  Cilium (eBPF CNI)          Traefik (Ingress Controller)                     │   │
│  │  ・Pod 間通信              ・外部 HTTP → Service ルーティング                   │   │
│  │  ・NetworkPolicy           ・*.homelab.local のドメイン振り分け                  │   │
│  │  ・Hubble 可観測性          ・externalIPs で全ノードからアクセス可能              │   │
│  └──────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                     │
│  ┌─── Layer 1: ストレージ基盤 ────────────────────────────────────────────────────┐   │
│  │  Longhorn (分散ブロックストレージ)                                              │   │
│  │  ・全アプリの PVC を提供 (デフォルト StorageClass)                               │   │
│  │  ・レプリカ数 1 (ラボ環境)                                                     │   │
│  │  ・iSCSI で Pod にマウント                                                     │   │
│  └──────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                     │
│  ┌─── Layer 2: セキュリティ・ポリシー基盤 ────────────────────────────────────────┐   │
│  │  Kyverno (Admission Controller)    cert-manager (TLS 証明書)                   │   │
│  │  ・リソース制限の強制             ・内部 CA による証明書自動発行                   │   │
│  │  ・latest タグ禁止               ・*.homelab.local 用証明書                     │   │
│  │  ・app ラベル必須                                                             │   │
│  └──────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                     │
│  ┌─── Layer 3: シークレット・オブジェクトストレージ ─────────────────────────────────┐   │
│  │  Vault (シークレット管理)          MinIO (S3 互換ストレージ)                      │   │
│  │  ・API キー・パスワード保管        ・Velero バックアップ先                        │   │
│  │  ・OIDC / userpass 認証           ・バケット: velero-backups                    │   │
│  │  ・自動 unseal (CronJob)                                                      │   │
│  └──────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                     │
│  ┌─── Layer 4: 認証基盤 ─────────────────────────────────────────────────────────┐   │
│  │  Keycloak (SSO / OIDC プロバイダ)                                              │   │
│  │  ・Realm: homelab                                                             │   │
│  │  ・全サービスに SSO を提供:                                                     │   │
│  │    Grafana / ArgoCD / Harbor / Vault / MinIO / Kibana                         │   │
│  │  ・グループ: homelab-admins → 各サービスの Admin ロールにマッピング               │   │
│  └──────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                     │
│  ┌─── Layer 5: GitOps・デプロイ基盤 ─────────────────────────────────────────────┐   │
│  │  ArgoCD (GitOps)              Harbor (コンテナレジストリ)                        │   │
│  │  ・Git → クラスタ同期          ・プライベートイメージ保存                         │   │
│  │  ・App of Apps パターン        ・Trivy 脆弱性スキャン内蔵                        │   │
│  │  ・Sync Wave で起動順制御      ・全ノードが pull 先として使用                     │   │
│  │                                                                               │   │
│  │  Argo Rollouts (プログレッシブデリバリー)                                       │   │
│  │  ・カナリア / Blue-Green デプロイ                                               │   │
│  │  ・Prometheus メトリクスによる自動判定                                           │   │
│  └──────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                     │
│  ┌─── Layer 6: 可観測性 (Observability) ─────────────────────────────────────────┐   │
│  │                                                                               │   │
│  │  ┌── Metrics ──┐  ┌── Logs ──────────┐  ┌── Traces ─────────┐               │   │
│  │  │ Prometheus  │  │ Fluent Bit       │  │ OTel Collector    │               │   │
│  │  │   ↓         │  │   ↓              │  │   ↓               │               │   │
│  │  │ Alertmanager│  │ Elasticsearch    │  │ Tempo             │               │   │
│  │  │   ↓         │  │   ↓              │  │   ↓               │               │   │
│  │  │ Grafana ◄───┼──┤ Kibana           │  │ Grafana           │               │   │
│  │  └─────────────┘  └──────────────────┘  └───────────────────┘               │   │
│  │                                                                               │   │
│  │  Falco (ランタイムセキュリティ)    Trivy Operator (脆弱性スキャン)               │   │
│  │  ・syscall 監視 → Alertmanager   ・イメージ / RBAC / 設定を定期スキャン          │   │
│  └──────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                     │
│  ┌─── Layer 7: 自動化・イベント駆動 ─────────────────────────────────────────────┐   │
│  │  Argo Workflows (ワークフロー実行)    Argo Events (イベントトリガー)              │   │
│  │  ・DAG で並列/順序実行               ・Webhook 受信 → Workflow 起動              │   │
│  │  ・自動修復ワークフロー実行           ・Alertmanager → EventSource → Sensor      │   │
│  │                                                                               │   │
│  │  KEDA (イベント駆動オートスケーリング)                                           │   │
│  │  ・Prometheus メトリクスで Pod 自動スケール                                      │   │
│  │  ・ScaledObject / ScaledJob                                                   │   │
│  └──────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                     │
│  ┌─── Layer 8: AIOps (AI 運用自動化) ────────────────────────────────────────────┐   │
│  │                                                                               │   │
│  │  ┌─ 予測アラート ─┐  ┌─ 異常検知 ──────┐  ┌─ 要約 ───────────┐               │   │
│  │  │ PrometheusRule │  │ CronJob (5分)   │  │ alert-summarizer │               │   │
│  │  │ ・ディスク枯渇  │  │ ・ES ログ分析    │  │ ・LLM で要約     │               │   │
│  │  │ ・CPU スパイク  │  │ ・Pushgateway   │  │ ・Webhook 受信   │               │   │
│  │  └───────┬────────┘  └────────────────┘  └──────────────────┘               │   │
│  │          ↓                                                                    │   │
│  │  ┌─ 自動修復 ────────────────────────────────────────────────┐                │   │
│  │  │ Alertmanager → Argo Events → Argo Workflows              │                │   │
│  │  │ ・CrashLoopBackOff → Pod 再起動 + ログ解析               │                │   │
│  │  │ ・OOMKilled → メモリ上限引き上げ                          │                │   │
│  │  │ ・Longhorn Faulted → instance-manager 再起動             │                │   │
│  │  └──────────────────────────────────────────────────────────┘                │   │
│  └──────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                     │
│  ┌─── Layer 9: バックアップ・DR ─────────────────────────────────────────────────┐   │
│  │  Velero (バックアップ)                                                         │   │
│  │  ・毎日 02:00 JST に全 namespace バックアップ                                   │   │
│  │  ・PVC データは FSB (ファイルシステムバックアップ) で MinIO に保存                 │   │
│  │  ・7 日間保持 (TTL: 168h)                                                     │   │
│  └──────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                     │
│  ┌─── Layer 10: 実験・将来基盤 ──────────────────────────────────────────────────┐   │
│  │  Litmus (カオスエンジニアリング)   Backstage (開発者ポータル)                     │   │
│  │  ・Pod/Node 障害注入テスト       ・サービスカタログ                              │   │
│  │  ・自動修復の動作検証            ・TechDocs                                    │   │
│  │                                                                               │   │
│  │  Crossplane (インフラ CRD 管理)                                                │   │
│  │  ・Terraform 代替候補            ・k8s CRD で VM 管理                          │   │
│  └──────────────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

---

## サービス間の依存関係

### 矢印の見方: `A → B` = A は B に依存する (B が先に起動している必要がある)

```
Cilium ──────────────────────────────────────────────── (依存なし: CNI は最初に必要)
  ↑
Traefik ─────────────────────────────────────────────── (Cilium の上で動作)
  ↑
全 Ingress を持つサービス ───────────────────────────── (Traefik 経由で外部公開)


Longhorn ────────────────────────────────────────────── (Cilium の上で動作)
  ↑
全 PVC を使うサービス ──────────────────────────────── (Longhorn が StorageClass 提供)
  │
  ├── Prometheus (10Gi)
  ├── Grafana (2Gi)
  ├── Elasticsearch (10Gi)
  ├── Vault (10Gi)
  ├── Harbor (10Gi + 5Gi × 4)
  ├── PostgreSQL for Keycloak (5Gi)
  ├── PostgreSQL for Backstage (5Gi)
  ├── MongoDB for Litmus (5Gi)
  ├── MinIO (20Gi)
  └── Tempo (10Gi)


Keycloak ──→ Longhorn (PostgreSQL PVC)
  ↑
  ├── Grafana (OAuth)
  ├── ArgoCD (OIDC)
  ├── Harbor (OIDC)
  ├── Vault (OIDC)
  ├── MinIO (OIDC)
  └── Kibana (oauth2-proxy → Keycloak)


Prometheus ──→ Longhorn
  ↑
  ├── Grafana (データソース)
  ├── Alertmanager (アラート送信)
  ├── KEDA (ScaledObject のメトリクスソース)
  └── Argo Rollouts (AnalysisTemplate のメトリクスソース)


Alertmanager ──→ Prometheus
  ↑
  ├── alert-summarizer (Webhook 受信)
  ├── Argo Events EventSource (Webhook 受信 → 自動修復トリガー)
  └── Falcosidekick (セキュリティアラート転送)


Elasticsearch ──→ Longhorn
  ↑
  ├── Fluent Bit (ログ出力先)
  ├── Kibana (ログ閲覧 UI)
  ├── Grafana (データソース)
  └── anomaly-detection CronJob (ログ取得元)


Argo Events ──→ Argo Workflows
  ↑
  └── Alertmanager (自動修復の Webhook トリガー)


MinIO ──→ Longhorn
  ↑
  └── Velero (バックアップ保存先)


Harbor ──→ Longhorn
  ↑
  ├── 全 Pod (イメージ pull 先)
  └── aiops image-build CronWorkflow (イメージ push 先)
```

---

## データフロー図

### メトリクス (Metrics) の流れ

```
各 Pod / Node
  │ /metrics エンドポイント公開
  ↓ (Pull: 30秒間隔)
Prometheus ──→ TSDB に保存 (7日間)
  │
  ├──→ Grafana (ダッシュボード表示)
  ├──→ Alertmanager (閾値超過時にアラート発火)
  ├──→ KEDA (ScaledObject がメトリクス参照してスケール)
  └──→ Argo Rollouts (AnalysisRun がメトリクス参照して判定)
```

### ログ (Logs) の流れ

```
各 Pod のコンテナ
  │ stdout/stderr → /var/log/containers/*.log
  ↓ (DaemonSet: 全ノード)
Fluent Bit ──→ メタデータ付与 (Pod名, namespace, labels)
  │
  ↓ (HTTP POST)
Elasticsearch ──→ インデックス: fluent-bit-YYYY.MM.DD
  │
  ├──→ Kibana (ログ検索・閲覧)
  ├──→ Grafana (Elasticsearch データソース)
  └──→ anomaly-detection CronJob (異常パターン検知)
```

### トレース (Traces) の流れ

```
アプリ (計装済み)
  │ OTLP gRPC (:4317) / HTTP (:4318)
  ↓
OpenTelemetry Collector ──→ batch + memory_limiter
  │
  ↓ (OTLP gRPC)
Tempo ──→ ローカルファイルシステムに保存 (24時間)
  │
  ↓
Grafana (Tempo データソース → Trace ID で検索)
```

### アラート → 自動修復の流れ

```
Prometheus
  │ PrometheusRule 評価 (例: KubePodCrashLooping)
  ↓
Alertmanager
  │ route マッチング (remediation label)
  ├──→ alert-summarizer (LLM 要約)
  ↓
Argo Events EventSource (HTTP Webhook :12000)
  │
  ↓
Argo Events Sensor (条件判定)
  │
  ↓
Argo Workflow (自動修復実行)
  │ 例: kubectl delete pod → 再起動
  │ 例: kubectl patch → メモリ上限引き上げ
  ↓
Grafana Annotation (修復結果を記録)
```

---

## ArgoCD Sync Wave (起動順序)

| Wave | サービス | 理由 |
|------|---------|------|
| 0 | Cilium, Kyverno | CNI とポリシーエンジンは最優先 |
| 1 | Kyverno Policies | Kyverno 本体が起動してから |
| 2 | Longhorn (prereqs + 本体) | PVC の前提条件 |
| 3 | Vault, MinIO, cert-manager | 他サービスの依存先 |
| 4 | Monitoring, Argo Workflows/Events/Rollouts, Velero, KEDA, Falco | コア機能群 |
| 5 | Harbor, Trivy Operator | レジストリ + スキャン |
| 6 | Keycloak | SSO (他サービスの OIDC 依存先) |
| 7-9 | Logging (ES → Fluent Bit → Kibana) | ES 起動後に Fluent Bit、最後に UI |
| 10-11 | Tracing (Tempo → OTel Collector) | バックエンド先に、収集は後 |
| 12-15 | AIOps (alerting → detection → remediation → events) | 段階的に有効化 |
| 16 | Litmus, Backstage, Crossplane | 実験的・将来用 |

**なぜ段階的に起動するか:** pve-node01 の e1000e NIC が一斉通信でハングするため、Sync Wave で負荷を分散する。

---

## ネットワークアクセス構成

```
ブラウザ (Windows)
  │
  │ hosts ファイル: *.homelab.local → 192.168.210.25 (worker04)
  ↓
k3s-worker04 (192.168.210.25)
  │
  │ Cilium BPF: externalIP → Traefik Service
  ↓
Traefik Pod
  │ Host ヘッダーで振り分け
  ├── grafana.homelab.local     → Grafana Service (monitoring ns)
  ├── argocd.homelab.local      → ArgoCD Server Service (argocd ns)
  ├── harbor.homelab.local      → Harbor Core Service (harbor ns)
  ├── keycloak.homelab.local    → Keycloak Service (keycloak ns)
  ├── vault.homelab.local       → Vault Service (vault ns)
  ├── kibana.homelab.local      → oauth2-proxy → Kibana (logging ns)
  ├── longhorn.homelab.local    → Longhorn UI (longhorn-system ns)
  ├── minio.homelab.local       → MinIO Console (minio ns)
  ├── argo-workflows.homelab.local → Argo Server (argo-workflows ns)
  └── alert-summarizer.homelab.local → alert-summarizer (aiops ns)
```

---

## Namespace 一覧

| Namespace | サービス | 用途 |
|-----------|---------|------|
| `kube-system` | Cilium, Traefik, CoreDNS | クラスタ基盤 |
| `longhorn-system` | Longhorn | 分散ストレージ |
| `kyverno` | Kyverno | ポリシーエンジン |
| `cert-manager` | cert-manager | TLS 証明書 |
| `vault` | Vault | シークレット管理 |
| `minio` | MinIO | オブジェクトストレージ |
| `keycloak` | Keycloak + PostgreSQL | SSO 認証 |
| `argocd` | ArgoCD | GitOps |
| `harbor` | Harbor | コンテナレジストリ |
| `monitoring` | Prometheus, Grafana, Alertmanager | メトリクス監視 |
| `logging` | Elasticsearch, Fluent Bit, Kibana | ログ管理 |
| `tracing` | Tempo, OTel Collector | 分散トレーシング |
| `argo-workflows` | Argo Workflows | ワークフロー |
| `argo-events` | Argo Events | イベント駆動 |
| `argo-rollouts` | Argo Rollouts | プログレッシブデリバリー |
| `aiops` | alerting, anomaly-detection, alert-summarizer, auto-remediation | AI 運用 |
| `keda` | KEDA | オートスケーリング |
| `falco` | Falco | ランタイムセキュリティ |
| `trivy-system` | Trivy Operator | 脆弱性スキャン |
| `velero` | Velero | バックアップ |
| `litmus` | LitmusChaos | カオスエンジニアリング |
| `backstage` | Backstage + PostgreSQL | 開発者ポータル |
| `crossplane-system` | Crossplane | インフラ CRD 管理 |
