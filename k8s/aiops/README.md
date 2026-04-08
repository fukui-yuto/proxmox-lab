# AIOps

既存の監視・ログスタックを活用して IT 運用を AI で知能化するコンポーネント群。

詳細な実施計画は [PLAN.md](./PLAN.md) を参照。

---

## ディレクトリ構成

| ディレクトリ | 内容 | 状態 |
|---|---|---|
| `alerting/` | 予測・トレンド型アラートルール (PrometheusRule / AlertManager 設定) | ✅ 完了 |
| `anomaly-detection/` | ログ異常検知 CronJob + Grafana ダッシュボード | ✅ 完了 |
| `alert-summarizer/` | LLM アラートサマリ (Claude API) | 未着手 |
| `auto-remediation/` | 自動修復 Runbook (Argo Events/Workflows) | 未着手 |

---

## Step 1: Grafana アラート知能化

### 概要

- `predict_linear()` を使った**予測型アラート** (ディスク・メモリ枯渇を事前検知)
- `rate()` / `increase()` を使った**トレンド型アラート** (CPU スパイク・Pod 再起動率)
- AlertManager の `inhibit_rules` による**ノイズ抑制**

### デプロイ

ArgoCD App `aiops-alerting` が `k8s/aiops/alerting/prometheusrule.yaml` を `monitoring` namespace へ自動適用する。

```bash
# 旧アプリ (aiops-step1-alerting) が残っている場合は削除
kubectl delete application aiops-step1-alerting -n argocd

# ArgoCD App を手動で適用する場合
kubectl apply -f k8s/argocd/apps/aiops.yaml
```

### アラート一覧

| アラート名 | 説明 | Severity |
|---|---|---|
| `DiskSpaceExhaustionIn24h` | ディスク空き容量が24時間以内に枯渇予測 | warning |
| `DiskSpaceExhaustionIn4h` | ディスク空き容量が4時間以内に枯渇予測 | critical |
| `CPUSpikeHighSustained` | CPU 使用率が85%超を10分継続 | warning |
| `CPUSpikeIncreaseRapid` | CPU 使用量が急増 | warning |
| `MemoryExhaustionIn2h` | メモリが2時間以内に枯渇予測 | warning |
| `NodeMemoryPressureHigh` | 空きメモリが10%未満 | critical |
| `PodRestartRateHigh` | Pod が1時間で3回以上再起動 | warning |
| `PodRestartRateCritical` | Pod が30分で5回以上再起動 | critical |
| `PrometheusStorageHigh` | Prometheus PVC 使用率が80%超 | warning |

---

## Step 2: ログ異常検知 CronJob

### 概要

Elasticsearch のログを5分ごとに集計し、ADTK (Anomaly Detection Toolkit) で異常を検知。
結果を Prometheus Pushgateway 経由で Grafana に可視化する。

### アーキテクチャ

```
Fluent-bit → Elasticsearch (fluent-bit-* インデックス)
                  ↓ ES Query API (5分ごと)
         [log-anomaly-detector CronJob]
         - InterQuartileRangeAD: 総ログ量の外れ値検知
         - LevelShiftAD: エラーログの急増検知
                  ↓ prometheus_client
         Prometheus Pushgateway → Prometheus → Grafana
```

### 検知メトリクス

| メトリクス名 | 説明 |
|---|---|
| `log_total_count` | 直近ウィンドウの総ログ件数 |
| `log_error_count` | 直近ウィンドウのエラーログ件数 |
| `log_error_rate` | エラーログ率 (errors / total) |
| `log_anomaly_total_detected` | 総ログ量の異常検知フラグ (1=異常) |
| `log_anomaly_error_detected` | エラーログ量の異常検知フラグ (1=異常) |
| `log_anomaly_error_shift_detected` | エラーログの急増フラグ (1=急増) |

### Grafana ダッシュボード

`http://grafana.homelab.local` → **Log Anomaly Detection** ダッシュボードで以下を確認できる。

| パネル | 内容 |
|---|---|
| Total Log Anomaly | 総ログ量の異常フラグ (緑=正常 / 赤=異常) |
| Error Log Anomaly | エラーログ量の異常フラグ |
| Error Log Level-Shift | エラーログの急増フラグ |
| Error Rate | 直近ウィンドウのエラー率 |
| Log Count (Total vs Error) | 総ログ数とエラーログ数の時系列 |
| Error Rate Trend | エラー率の時系列 |
| Anomaly Flags Timeline | 3つの異常フラグの時系列 |

ダッシュボードは `k8s/monitoring/dashboards/log-anomaly-cm.yaml` の ConfigMap (label: `grafana_dashboard=1`) として管理。
ArgoCD monitoring app の sync で自動適用される。

### デプロイ手順

#### 1. Harbor を起動

```bash
kubectl apply -f k8s/argocd/apps/harbor.yaml
# Harbor が Ready になるまで待機 (5〜10分)
kubectl get pods -n harbor -w
```

#### 2. ArgoCD App を適用 (Pushgateway + CronJob namespace)

```bash
kubectl apply -f k8s/argocd/apps/aiops.yaml
```

#### 3. Harbor に anomaly-detector イメージをビルド・push (kaniko)

```bash
# aiops namespace と Harbor 認証 Secret を作成
kubectl apply -f k8s/aiops/anomaly-detection/namespace.yaml
kubectl create secret docker-registry harbor-registry-secret \
  --docker-server=harbor.homelab.local \
  --docker-username=admin \
  --docker-password=Harbor12345 \
  -n aiops

# kaniko Job でイメージをビルド・push
kubectl apply -f k8s/aiops/anomaly-detection/kaniko-job.yaml

# ビルドログを確認
kubectl logs -f job/build-anomaly-detector -n aiops
```

#### 4. CronJob を確認

```bash
# CronJob の状態確認
kubectl get cronjob -n aiops

# 手動実行でテスト
kubectl create job --from=cronjob/log-anomaly-detector test-run -n aiops
kubectl logs -f job/test-run -n aiops

# Pushgateway でメトリクス確認
kubectl port-forward svc/prometheus-pushgateway 9091:9091 -n monitoring
# → http://localhost:9091 でメトリクス確認
```

### 設定値

| 環境変数 | デフォルト | 説明 |
|---|---|---|
| `ES_URL` | `http://elasticsearch-master.logging.svc.cluster.local:9200` | ES エンドポイント |
| `PUSHGATEWAY_URL` | `http://aiops-pushgateway-prometheus-pushgateway.monitoring.svc.cluster.local:9091` | Pushgateway エンドポイント |
| `LOOKBACK_HOURS` | `6` | 過去何時間分のログを集計するか |
| `WINDOW_MINUTES` | `5` | 集計ウィンドウ (分) |
| `ES_INDEX_PATTERN` | `fluent-bit-*` | ES インデックスパターン |
