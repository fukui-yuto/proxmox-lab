# AIOps

既存の監視・ログスタックを活用して IT 運用を AI で知能化するコンポーネント群。

詳細な実施計画は [PLAN.md](./PLAN.md) を参照。

---

## ディレクトリ構成

| ディレクトリ | 内容 | 状態 |
|---|---|---|
| `step1-alerting/` | Grafana アラート知能化 (PrometheusRule / AlertManager 設定) | ✅ 完了 |
| `step2-log-anomaly/` | ログ異常検知 CronJob | 未着手 |
| `step3-llm-summary/` | LLM アラートサマリ (Claude API) | 未着手 |
| `step4-auto-remediation/` | 自動修復 Runbook (Argo Events/Workflows) | 未着手 |

---

## Step 1: Grafana アラート知能化

### 概要

- `predict_linear()` を使った**予測型アラート** (ディスク・メモリ枯渇を事前検知)
- `rate()` / `increase()` を使った**トレンド型アラート** (CPU スパイク・Pod 再起動率)
- AlertManager の `inhibit_rules` による**ノイズ抑制**

### デプロイ方法

ArgoCD App `aiops-step1-alerting` が自動的に `k8s/aiops/step1-alerting/prometheusrule.yaml` を `monitoring` namespace へ適用する。

```bash
# ArgoCD App を手動で適用する場合
kubectl apply -f k8s/argocd/apps/aiops.yaml
```

### アラート一覧

| アラート名 | 説明 | Severity |
|---|---|---|
| `DiskSpaceExhaustionIn24h` | ディスク空き容量が24時間以内に枯渇予測 | warning |
| `DiskSpaceExhaustionIn4h` | ディスク空き容量が4時間以内に枯渇予測 | critical |
| `CPUSpikeHighSustained` | CPU 使用率が85%超を10分継続 | warning |
| `CPUSpikeIncreaseRapid` | CPU 使用量が急増 (10分で急増) | warning |
| `MemoryExhaustionIn2h` | メモリが2時間以内に枯渇予測 | warning |
| `NodeMemoryPressureHigh` | 空きメモリが10%未満 | critical |
| `PodRestartRateHigh` | Pod が1時間で3回以上再起動 | warning |
| `PodRestartRateCritical` | Pod が30分で5回以上再起動 | critical |
| `PrometheusStorageHigh` | Prometheus PVC 使用率が80%超 | warning |

### AlertManager 変更点

`k8s/monitoring/values.yaml` に以下を追加:

- `group_by` を `["namespace", "alertname", "severity"]` に拡張
- `repeat_interval` を 12h → 4h に短縮
- `inhibit_rules` を追加:
  - ノードダウン時に Pod/コンテナアラートを抑制
  - Critical 発火中は同一 instance の Warning を抑制

### アラート確認方法

```bash
# PrometheusRule が適用されているか確認
kubectl get prometheusrules -n monitoring

# Prometheus で発火中のアラートを確認
# http://grafana.homelab.local → Alerting → Alert Rules
```
