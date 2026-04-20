# Trivy Operator ガイド

## 概要

Trivy Operator は Kubernetes クラスター内のコンテナイメージ・設定・RBAC を継続的にスキャンし、結果を CRD (Custom Resource) として k8s に保存するセキュリティスキャナー。

### スキャン対象

| スキャン種別 | CRD | 内容 |
|------------|-----|------|
| 脆弱性 | `VulnerabilityReport` | コンテナイメージの CVE |
| 設定監査 | `ConfigAuditReport` | Deployment/Pod のセキュリティ設定ミス |
| インフラ評価 | `InfraAssessmentReport` | ノード・クラスターの設定確認 |
| RBAC 評価 | `RbacAssessmentReport` | 過剰な権限の RBAC |
| 露出シークレット | `ExposedSecretReport` | コンテナ内の平文シークレット |

---

## スキャン結果の確認

```bash
# 脆弱性レポート一覧
kubectl get vulnerabilityreport -A

# 特定の namespace の詳細
kubectl get vulnerabilityreport -n my-namespace -o wide

# 高・致命的な脆弱性のみフィルタ
kubectl get vulnerabilityreport -A -o json | \
  jq '.items[] | select(.report.summary.criticalCount > 0 or .report.summary.highCount > 0) | .metadata.name'

# 設定監査レポート
kubectl get configauditreport -A

# RBAC 評価レポート
kubectl get rbacassessmentreport -A
```

---

## Harbor との統合

Harbor のプロジェクト設定でプッシュ時スキャンを有効化すると、
イメージプッシュ → Harbor スキャン → Trivy Operator クラスター内スキャンの二重チェックになる。

```
開発者 → docker push → Harbor (プッシュ時スキャン)
                              ↓
                    k8s デプロイ → Trivy Operator (実行時スキャン)
```

---

## Grafana ダッシュボード

Trivy Operator は Prometheus メトリクスを公開する。kube-prometheus-stack と統合されているため、
Grafana でスキャン結果を可視化できる。

インポート用ダッシュボード ID: `17813` (Trivy Operator Dashboard)

---

## Kyverno との統合例

Trivy の脆弱性レポートを Kyverno ポリシーで参照し、HIGH 以上の CVE があるイメージのデプロイをブロックする構成も可能。

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: block-vulnerable-images
spec:
  validationFailureAction: Enforce
  rules:
    - name: check-vulnerabilities
      match:
        resources:
          kinds: [Pod]
      verify:
        - imageReferences: ["*"]
          attestors:
            - entries:
                - keyless:
                    rekor:
                      url: https://rekor.sigstore.dev
```

---

## スキャン間隔の調整

homelab のリソースに合わせて `operator.scanJobTTL` で TTL を調整する。
デフォルトは 24h ごとに再スキャン。並列スキャン数は `concurrentScanJobsLimit: "3"` に制限済み。

---

## ファイル構成と各ファイルのコード解説

### ファイル構成一覧

| ファイルパス | 役割 | 説明 |
|---|---|---|
| `k8s/trivy-operator/values.yaml` | Helm values | Trivy Operator の全設定を定義する Helm チャートのカスタム値ファイル。スキャン間隔・有効化フラグ・リソース制限などを記述 |
| `k8s/trivy-operator/README.md` | 手順書 | セットアップ手順・確認コマンド・ファイル構成の概要を記載 |
| `k8s/trivy-operator/GUIDE.md` | 概念ガイド | 本ファイル。Trivy Operator の仕組み・CRD 種別・統合パターンの学習用ドキュメント |
| `k8s/argocd/apps/trivy-operator.yaml` | ArgoCD Application | ArgoCD が Trivy Operator を GitOps で管理するための Application マニフェスト |

---

### values.yaml の全設定解説

`k8s/trivy-operator/values.yaml` は Helm チャート `aquasecurity/trivy-operator` に渡すカスタム設定ファイル。
以下、セクションごとに全設定項目を詳しく解説する。

---

#### `operator` セクション — Operator 本体の動作設定

```yaml
operator:
  scanJobTTL: "24h"
  vulnerabilityScannerEnabled: true
  configAuditScannerEnabled: true
  infraAssessmentScannerEnabled: true
  rbacAssessmentScannerEnabled: true
  exposedSecretScannerEnabled: true
  sbomGenerationEnabled: false
  concurrentScanJobsLimit: "3"
```

| 設定キー | 値 | 説明 |
|---|---|---|
| `scanJobTTL` | `"24h"` | スキャンジョブの再実行間隔。前回のスキャン完了から指定時間が経過すると、対象リソースを再スキャンする。homelab では 24 時間が適切。短くするとリソース消費が増えるため注意 |
| `vulnerabilityScannerEnabled` | `true` | **脆弱性スキャナー**を有効化する。コンテナイメージに含まれる OS パッケージやライブラリの既知の脆弱性 (CVE) を検出し、`VulnerabilityReport` CRD に結果を保存する。最も基本的なスキャン機能 |
| `configAuditScannerEnabled` | `true` | **設定監査スキャナー**を有効化する。Deployment や Pod のセキュリティ設定 (例: root 実行、特権コンテナ、hostNetwork 使用) をチェックし、`ConfigAuditReport` CRD にベストプラクティス違反を記録する |
| `infraAssessmentScannerEnabled` | `true` | **インフラ評価スキャナー**を有効化する。Kubernetes ノードやクラスター全体の設定 (kubelet 設定、API サーバー設定) を CIS ベンチマークに基づいて評価し、`InfraAssessmentReport` CRD に保存する |
| `rbacAssessmentScannerEnabled` | `true` | **RBAC 評価スキャナー**を有効化する。ClusterRole / Role / RoleBinding を分析し、過剰な権限 (例: `*` ワイルドカード、secrets への広範なアクセス) を検出して `RbacAssessmentReport` CRD に記録する |
| `exposedSecretScannerEnabled` | `true` | **露出シークレットスキャナー**を有効化する。コンテナイメージのファイルシステム内に平文で保存されたシークレット (API キー、パスワード、証明書) を検出し、`ExposedSecretReport` CRD に記録する |
| `sbomGenerationEnabled` | `false` | **SBOM (Software Bill of Materials) 生成**を無効化。有効にするとコンテナイメージの構成パッケージ一覧を `SbomReport` CRD に保存する。homelab ではリソース節約のため無効にしている |
| `concurrentScanJobsLimit` | `"3"` | **同時実行スキャンジョブ数の上限**。Trivy Operator はスキャン対象ごとに短命の Job (Pod) を作成する。homelab のような限られたリソース環境では、同時に実行される Job が多すぎるとノードの CPU/メモリが逼迫するため 3 に制限している |

**初心者向け補足:**
- `scanJobTTL` は「何時間おきにスキャンするか」の設定。新しい Pod がデプロイされた場合は TTL に関係なく即座にスキャンされる
- 各スキャナーの `Enabled` フラグを `false` にすると、その種類のスキャンが完全に停止する。不要なスキャンを無効化するとクラスターの負荷を軽減できる
- `concurrentScanJobsLimit` は非常に重要。値を大きくするとスキャンは速くなるが、homelab のワーカーノード (4GB RAM) では OOM が発生しやすくなる

---

#### `trivy` セクション — Trivy スキャンエンジンの設定

```yaml
trivy:
  ignoreUnfixed: true
  severity: "UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL"
  timeout: "5m0s"
```

| 設定キー | 値 | 説明 |
|---|---|---|
| `ignoreUnfixed` | `true` | **修正パッチが未提供の脆弱性を無視する**。`true` にすると、まだ修正版がリリースされていない CVE はレポートに含まれない。対処不可能なノイズを減らし、実際にアクション可能な脆弱性に集中できる |
| `severity` | `"UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL"` | **レポートに含める脆弱性の重大度レベル**。カンマ区切りで指定する。全レベルを含めているため、すべての脆弱性が記録される。`HIGH,CRITICAL` のみにすると低リスクのノイズを排除できる |
| `timeout` | `"5m0s"` | **1 回のスキャンのタイムアウト時間**。大きなイメージ (例: ML フレームワーク入りのイメージ) はスキャンに時間がかかるため、5 分に設定。タイムアウトするとスキャンは失敗扱いになり次の TTL サイクルで再試行される |

**初心者向け補足:**
- `ignoreUnfixed: true` は「今すぐ対処できない問題は表示しない」というプラグマティックな設定。セキュリティ監査目的で全 CVE を把握したい場合は `false` にする
- `severity` で `HIGH,CRITICAL` のみに絞ると、Grafana ダッシュボードや Kyverno ポリシーで「本当に危険なもの」だけをアラートできる

---

#### `serviceMonitor` セクション — Prometheus 連携

```yaml
serviceMonitor:
  enabled: true
```

| 設定キー | 値 | 説明 |
|---|---|---|
| `enabled` | `true` | **Prometheus ServiceMonitor CRD を作成する**。kube-prometheus-stack (monitoring) がインストールされている環境で `true` にすると、Prometheus が Trivy Operator のメトリクスを自動収集する。Grafana ダッシュボード (ID: 17813) で脆弱性数の推移やスキャン成功率を可視化できる |

**初心者向け補足:**
- ServiceMonitor は「Prometheus にこのサービスのメトリクスを取りに来てね」と伝えるための Kubernetes カスタムリソース
- この設定が `false` だと Grafana で Trivy のデータが表示されなくなる

---

#### `resources` セクション — Operator Pod のリソース制限

```yaml
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi
```

| 設定キー | 値 | 説明 |
|---|---|---|
| `requests.cpu` | `100m` | **CPU の予約量**。Operator Pod が最低限確保する CPU リソース。100m = 0.1 コア。スケジューラはこの値を基にノードへの配置を決定する |
| `requests.memory` | `128Mi` | **メモリの予約量**。Operator Pod が最低限確保するメモリ。128MiB はアイドル時に十分な量 |
| `limits.cpu` | `500m` | **CPU の上限**。バースト時に使用できる最大 CPU。0.5 コアまで。スキャンジョブの作成・管理時に一時的に CPU を使う |
| `limits.memory` | `512Mi` | **メモリの上限**。この値を超えると OOM Killer により Pod が強制終了される。512MiB は多数のスキャンレポートを管理する際に必要 |

**初心者向け補足:**
- `requests` は「最低限これだけは確保してください」という宣言。ノードに空きリソースがない場合、Pod はスケジュールされない (Pending 状態)
- `limits` は「これ以上は絶対に使わせない」という上限。特にメモリの `limits` を超えると Pod が即座に Kill される
- この設定は Operator 本体 (コントローラ Pod) のリソース。実際のスキャンは別の短命 Job Pod で実行されるため、スキャン自体のリソースは別途 Trivy が管理する
- homelab では worker ノードのメモリが限られている (4-8GB) ため、控えめな値に設定している

---

#### ArgoCD Application (`k8s/argocd/apps/trivy-operator.yaml`) の解説

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: trivy-operator
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "5"
spec:
  project: default
  sources:
    - repoURL: https://aquasecurity.github.io/helm-charts/
      chart: trivy-operator
      targetRevision: "0.24.1"
      helm:
        valueFiles:
          - $values/k8s/trivy-operator/values.yaml
    - repoURL: https://github.com/fukui-yuto/proxmox-lab
      targetRevision: HEAD
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: trivy-system
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

| 設定キー | 値 | 説明 |
|---|---|---|
| `sync-wave: "5"` | Wave 5 | ArgoCD の起動順序。Longhorn (Wave 2) や Vault (Wave 3) の後に起動する。Trivy は他のアプリに依存しないが、クラスター負荷分散のため Wave 5 に配置 |
| `sources[0]` | Helm チャート | aquasecurity の公式 Helm リポジトリからバージョン `0.24.1` のチャートを取得する |
| `sources[1]` | values 参照 | Git リポジトリの `k8s/trivy-operator/values.yaml` を Helm values として参照する (`$values` 変数) |
| `namespace: trivy-system` | デプロイ先 | Trivy Operator 専用の namespace に分離 |
| `automated.prune` | `true` | Git から削除されたリソースをクラスターからも自動削除 |
| `automated.selfHeal` | `true` | 手動変更が検出された場合、Git の状態に自動で戻す |
| `CreateNamespace=true` | NS 自動作成 | `trivy-system` namespace が存在しない場合に自動作成 |
| `ServerSideApply=true` | SSA 使用 | 大きな CRD リソースのフィールド衝突を回避するためサーバーサイド適用を使用 |
