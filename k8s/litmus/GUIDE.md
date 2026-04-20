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

---

## ファイル構成と各ファイルのコード解説

### ファイル構成一覧

```
k8s/litmus/
├── values.yaml      # Helm values (LitmusChaos のカスタム設定)
├── README.md        # セットアップ手順・トラブルシューティング
└── GUIDE.md         # 本ファイル (概念説明・実験種別・連携シナリオ)

k8s/argocd/apps/
└── litmus.yaml      # ArgoCD Application (自動デプロイ定義)
```

---

### values.yaml の詳細解説

LitmusChaos Helm chart (`litmuschaos/litmus`) に渡すカスタム値を定義するファイル。
chart のデフォルト値をこのファイルで上書きし、homelab 環境に合わせた設定にしている。

#### portal.frontend セクション

```yaml
portal:
  frontend:
    service:
      type: ClusterIP
    ingress:
      enabled: true
      annotations:
        kubernetes.io/ingress.class: traefik
      host: litmus.homelab.local
    resources:
      requests:
        cpu: 50m
        memory: 128Mi
      limits:
        cpu: 500m
        memory: 256Mi
```

- **`service.type: ClusterIP`**: フロントエンドのサービスをクラスタ内部 IP のみで公開する。外部からのアクセスは Ingress 経由で行うため NodePort や LoadBalancer は不要。
- **`ingress.enabled: true`**: Kubernetes Ingress リソースを自動作成する。これにより `litmus.homelab.local` というホスト名でブラウザからアクセスできるようになる。
- **`annotations.kubernetes.io/ingress.class: traefik`**: homelab で使用している Traefik Ingress Controller にルーティングを任せる指定。
- **`host: litmus.homelab.local`**: ブラウザからアクセスする際のホスト名。Windows の hosts ファイルに対応する IP を追記する必要がある。
- **`resources`**: フロントエンドコンテナに割り当てる CPU / メモリのリソース制限。`requests` は Pod スケジューリング時の保証値、`limits` は上限値。homelab はリソースが限られるため小さめに設定している。

#### portal.server セクション

```yaml
  server:
    resources:
      requests:
        cpu: 50m
        memory: 128Mi
      limits:
        cpu: 500m
        memory: 512Mi
```

- **server**: Chaos Center のバックエンド API サーバー。フロントエンドからの API リクエストを処理し、MongoDB に実験データを永続化する。
- メモリ上限が frontend (256Mi) より大きい (512Mi) のは、実験の実行管理やスケジューリングなどの処理が多いため。

#### portal.authServer セクション

```yaml
  authServer:
    resources:
      requests:
        cpu: 20m
        memory: 64Mi
      limits:
        cpu: 200m
        memory: 128Mi
```

- **authServer**: Chaos Center のログイン認証を担当するサーバー。ユーザー管理・トークン発行を行う。
- 認証処理は軽量なため、他コンポーネントと比較してリソース割り当てが小さい。

#### mongodb セクション

```yaml
mongodb:
  # chart 3.28.0: bitnamilegacy/mongodb:8.0.13-debian-12-r0 を使用
  replicaCount: 1
  resources:
    requests:
      cpu: 50m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 512Mi
  persistence:
    enabled: true
    storageClass: longhorn
    size: 5Gi
  volumePermissions:
    enabled: true
```

- **`replicaCount: 1`**: MongoDB のレプリカ数を 1 に設定。chart 3.28.0 ではデフォルトが 3 に変更されたが、homelab ではリソース節約のためシングルインスタンスにしている。本番環境では 3 以上が推奨されるが、カオス実験のメタデータ保存用途であるため 1 で十分。
- **`persistence.enabled: true`**: MongoDB のデータを永続ボリュームに保存する。Pod が再起動しても実験データが失われない。
- **`persistence.storageClass: longhorn`**: homelab の分散ストレージ Longhorn を使用。ノード障害時にもデータが保護される。
- **`persistence.size: 5Gi`**: MongoDB に 5GB のディスクを割り当てる。カオス実験のメタデータ保存には十分な容量。
- **`volumePermissions.enabled: true`**: Init Container を使って永続ボリュームのパーミッション (所有者) を MongoDB コンテナが読み書きできるように修正する。Longhorn ボリュームは root 所有で作成されるため、MongoDB (非 root ユーザーで実行) がアクセスするにはこの設定が必要。
