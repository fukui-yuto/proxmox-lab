# LitmusChaos ガイド

## 概要

LitmusChaos は Kubernetes 向けのカオスエンジニアリングフレームワーク。
意図的に Pod 障害・ノード障害・ネットワーク遅延などを注入し、システムの回復力を検証する。
homelab では **aiops-auto-remediation の動作検証** を主目的として使用する。

---

## 主要コンポーネント

| コンポーネント | 役割 |
|-------------|------|
| Chaos Center | Web UI・実験管理ポータル |
| Chaos Operator | CRD を監視してカオス実験を実行 |
| Chaos Exporter | Prometheus メトリクス公開 |
| ChaosEngine | 実験の実行定義 |
| ChaosExperiment | カオス種別の定義 |

---

## カオス実験の種類

### Pod レベル

| 実験 | 内容 |
|------|------|
| `pod-delete` | Pod を強制削除 |
| `pod-cpu-hog` | Pod の CPU を消費させる |
| `pod-memory-hog` | Pod のメモリを消費させる |
| `pod-network-latency` | Pod の送受信に遅延を追加 |
| `pod-network-loss` | Pod のパケットをドロップ |
| `container-kill` | コンテナプロセスを強制終了 |

### ノードレベル

| 実験 | 内容 |
|------|------|
| `node-drain` | ノードを drain する |
| `node-cpu-hog` | ノード全体の CPU を消費 |
| `node-memory-hog` | ノード全体のメモリを消費 |
| `kubelet-service-kill` | kubelet を一時停止 |

---

## ChaosEngine の例

```yaml
apiVersion: litmuschaos.io/v1alpha1
kind: ChaosEngine
metadata:
  name: pod-delete-test
  namespace: default
spec:
  appinfo:
    appns: default
    applabel: "app=my-app"
    appkind: deployment
  engineState: active
  chaosServiceAccount: litmus-admin
  experiments:
    - name: pod-delete
      spec:
        components:
          env:
            - name: TOTAL_CHAOS_DURATION
              value: "30"  # 30秒間
            - name: CHAOS_INTERVAL
              value: "10"  # 10秒ごとに削除
            - name: FORCE
              value: "false"
```

---

## aiops-auto-remediation との連携シナリオ

```
1. LitmusChaos が Pod を強制削除
   ↓
2. Alertmanager が PodCrashLooping アラートを発火
   ↓
3. aiops-auto-remediation が Argo Workflow をトリガー
   ↓
4. Workflow が Pod を再起動 / スケールアップ
   ↓
5. 回復時間を Grafana で計測
```

---

## Chaos Center へのアクセス

```
URL: http://litmus.homelab.local
初期ユーザー: admin
初期パスワード: litmus (初回ログイン時に変更が求められる)
```

---

## 確認コマンド

```bash
# ChaosEngine 一覧
kubectl get chaosengine -A

# 実験結果
kubectl get chaosresult -A

# Chaos Operator のログ
kubectl logs -n litmus -l app=chaos-operator -f
```
