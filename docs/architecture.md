# 最終アーキテクチャ設計書

全 Phase 実装後の最終的なシステム構成。

---

## インフラ層 (Proxmox VM / LXC)

```
[pve-node01]                          [pve-node02]
  ├── k3s-master      (1C / 1GB)        ├── (フェイルオーバー先)
  ├── k3s-worker01    (1C / 2GB)        └── PBS  (1C / 1GB)  ← バックアップ専用
  ├── k3s-worker02    (1C / 2GB)
  ├── dns-ct          (1C / 256MB)      ← Pi-hole (内部 DNS)
  ├── router-vm       (1C / 512MB)      ← VyOS (ソフトウェアルーター)
  └── keycloak-vm     (1C / 1GB)        ← SSO / OIDC 基盤
```

---

## アプリ層 (k3s クラスター内)

```
[k3s クラスター]
  │
  ├── ネットワーク
  │     └── Cilium                  ← CNI + eBPF + Hubble (ネットワーク可視化)
  │
  ├── GitOps / CI/CD
  │     ├── ArgoCD                  ← GitHub → k3s 自動デプロイ (GitOps)
  │     └── Harbor                  ← プライベートコンテナレジストリ + 脆弱性スキャン
  │
  ├── オブザーバビリティ
  │     ├── Prometheus              ← メトリクス収集
  │     ├── Alertmanager            ← アラート通知 (Slack / LINE)
  │     ├── Fluent Bit (DaemonSet)  ← ログ収集・フィルタリング
  │     ├── OpenTelemetry Collector ← トレース収集・変換
  │     ├── Grafana Tempo           ← トレース保存
  │     └── Grafana                 ← メトリクス・ログ・トレースを一元可視化
  │
  ├── セキュリティ
  │     └── HashiCorp Vault         ← シークレット管理・内部 CA (PKI)
  │
  └── ポリシー
        └── Kyverno                 ← Kubernetes ポリシー強制
```

---

## 認証フロー (Keycloak で SSO 統一)

Keycloak を唯一の認証基盤とし、全サービスのログインを一元化する。

```
[Keycloak (専用 VM)]
  ├── Proxmox VE   (OIDC)
  ├── Grafana      (OAuth2)
  ├── ArgoCD       (OIDC)
  └── Harbor       (OIDC)
```

> Keycloak を k3s 外の専用 VM に配置することで、k3s 障害時も認証基盤が生き残る。

---

## オブザーバビリティ データフロー

Grafana 1本にメトリクス・ログ・トレースを統合する。Kibana は使用しない。

```
                    ┌─────────────────────────────┐
                    │         Grafana              │
                    │  (メトリクス / ログ / トレース) │
                    └──────┬──────────┬────────────┘
                           │          │           │
                    Prometheus    Elasticsearch  Grafana Tempo
                           │          │           │
               node_exporter   Fluent Bit    OpenTelemetry
               kube metrics    (DaemonSet)    Collector
               各 VM / Pod     各 Pod ログ    各 Pod トレース
```

| データ種別 | 収集 | 保存 | 可視化 |
|-----------|------|------|--------|
| メトリクス | Prometheus + node_exporter | Prometheus | Grafana |
| ログ | Fluent Bit | Elasticsearch | Grafana (ES データソース) |
| トレース | OpenTelemetry Collector | Grafana Tempo | Grafana |

---

## GitOps フロー

```
[開発者 (このPC)]
      │  git push
      ▼
[GitHub リポジトリ]
      │  変更検知
      ▼
[ArgoCD]
      │  自動同期
      ▼
[k3s クラスター]
```

コンテナイメージは Harbor に push し、ArgoCD が Harbor から pull してデプロイする。

```
docker build → Harbor (プライベートレジストリ) → ArgoCD → k3s
```

---

## ネットワーク構成

```
[インターネット]
      │
[ルーター / ONU]
      │
[L2 マネージドスイッチ]  ← VLAN タギング
   │         │
[node01]  [node02]
      │
[router-vm / VyOS]  ← VLAN 間ルーティング・ファイアウォール

VLAN 1  (192.168.210.0/24)  管理 / Proxmox Web UI / Keycloak
VLAN 10 (192.168.211.0/24)  k3s VM / アプリ通信
VLAN 20 (192.168.212.0/24)  ストレージ / Proxmox Replication
```

---

## VM / LXC 一覧 (最終形)

| 名前 | 種別 | IP | vCPU | RAM | 用途 |
|------|------|----|------|-----|------|
| k3s-master | VM | 192.168.211.21 | 1 | 1GB | k3s コントロールプレーン |
| k3s-worker01 | VM | 192.168.211.22 | 1 | 2GB | k3s ワーカー |
| k3s-worker02 | VM | 192.168.211.23 | 1 | 2GB | k3s ワーカー |
| dns-ct | LXC | 192.168.210.53 | 1 | 256MB | Pi-hole (内部 DNS) |
| router-vm | VM | 192.168.210.1 | 1 | 512MB | VyOS (ソフトウェアルーター) |
| keycloak-vm | VM | 192.168.210.20 | 1 | 1GB | Keycloak (SSO / OIDC) |
| pbs | VM | 192.168.210.30 | 1 | 1GB | Proxmox Backup Server |
| elasticsearch | VM | 192.168.211.40 | 1 | 2GB | Elasticsearch |

---

## 現構成からの主な変更点

| 項目 | 変更前 | 変更後 | 理由 |
|------|--------|--------|------|
| k3s worker RAM | 1GB | 2GB | Phase 2 以降のサービス増加に対応 |
| ログ可視化 | Kibana | Grafana (ES データソース) | 一元化・リソース節約 |
| Elasticsearch | k3s StatefulSet | 専用 VM | 安定性・データ永続化 |
| Keycloak | k3s Deployment | 専用 VM | k3s 障害時も認証基盤を維持 |

---

## 参照ドキュメント

| ドキュメント | 内容 |
|------------|------|
| [design.md](design.md) | ハードウェア・ネットワーク・ストレージ設計 |
| [roadmap.md](roadmap.md) | 実装フェーズと優先順位 |
| [resource-planning.md](resource-planning.md) | リソース試算・判定 |
| [runbook.md](runbook.md) | 構築手順書 |
