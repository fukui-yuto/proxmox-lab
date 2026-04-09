# Argo Events

k3s クラスター上に Argo Events をデプロイする。
AIOps の自動修復 Runbook で AlertManager からのアラートを受信し、Argo Workflows のトリガーとして使用する。

## 構成

- **chart**: `argo-events` v2.4.9 (https://argoproj.github.io/argo-helm)
- **namespace**: `argo-events`
- **ArgoCD app**: `argo-events`
- **Sync Wave**: 3 (monitoring / argo-workflows と同タイミング)
- **Sync 方式**: 手動 (オンデマンド)

---

## デプロイ手順

ArgoCD UI または kubectl で手動 Sync する。

```bash
# ArgoCD Application を適用
kubectl apply -f k8s/argocd/apps/argo-events.yaml

# Pod が Ready になるまで待機
kubectl get pods -n argo-events -w
```

> Argo Workflows と合わせてデプロイすること。

---

## 自動修復での使用方法

aiops の auto-remediation が以下のリソースを `argo-events` namespace に作成する。

| リソース | 内容 |
|---|---|
| EventBus | NATS native メッセージバス |
| EventSource | AlertManager からの webhook 受信 (`:12000/oomkilled` / `:12000/crashloop`) |
| Sensor (OOMKilled) | OOMKilled アラートを受信 → `remediate-oomkilled` Workflow を起動 |
| Sensor (CrashLoop) | CrashLoopBackOff アラートを受信 → `remediate-crashloop` Workflow を起動 |

```bash
# EventBus / EventSource / Sensor の状態確認
kubectl get eventbus,eventsource,sensor -n argo-events

# EventSource が Listen しているか確認
kubectl get svc -n argo-events | grep eventsource
```

---

## アーキテクチャ

```
AlertManager
  ├─→ HTTP POST /oomkilled  → EventSource → Sensor → remediate-oomkilled Workflow
  └─→ HTTP POST /crashloop  → EventSource → Sensor → remediate-crashloop Workflow
            (EventBus: NATS)
```

詳細は [aiops/README.md](../aiops/README.md#step-4-自動修復-runbook-auto-remediation) を参照。

---

## 動作確認

```bash
# Pod 状態確認
kubectl get pods -n argo-events

# 期待する出力
NAME                                         READY   STATUS    RESTARTS
argo-events-controller-manager-xxxxx         1/1     Running   0
```

---

## アンインストール

```bash
kubectl delete application argo-events -n argocd
kubectl delete namespace argo-events
```
