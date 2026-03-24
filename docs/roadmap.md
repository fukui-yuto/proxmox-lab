# 今後の実装ロードマップ

このラボで今後追加・実装する技術のまとめ。
優先度順に Phase を分けて管理する。

---

## 現在のラボ状態

```
[Proxmox クラスター "homelab"]
  pve-node01 / pve-node02 (NUC5i3RYH × 2)
  ├── k3s-master  (192.168.211.21)
  ├── k3s-worker01 (192.168.211.22)
  ├── k3s-worker02 (192.168.211.23)
  └── dns-ct / Pi-hole (192.168.210.53)
```

---

## Phase 1 — 基盤の完成 (設計済み・未実装)

設計書に定義済みだがまだ実装していないもの。

| 項目 | 技術 | 配置先 | ステータス |
|------|------|--------|-----------|
| バックアップ基盤 | Proxmox Backup Server (PBS) | VM (Debian) | 未実装 |
| メトリクス収集 | Prometheus + node_exporter | LXC または k3s | 未実装 |
| メトリクス可視化 | Grafana | LXC または k3s | 未実装 |
| アラート | Alertmanager (Slack / LINE 通知) | k3s | 未実装 |
| ソフトウェアルーター | VyOS または pfSense | VM | 未実装 |

---

## Phase 2 — オブザーバビリティスタック

ログ・メトリクス・トレースの三本柱を揃える。

### 2-1. EFK スタック (ログ管理)

```
[k3s DaemonSet]         [Proxmox ホスト]
  Fluent Bit       +      Fluent Bit / Logstash
       |                       |
       └──────────┬────────────┘
                  ↓
          Elasticsearch  (k3s StatefulSet)
                  |
              Kibana     (k3s Deployment)
```

| コンポーネント | 役割 | リソース目安 |
|--------------|------|------------|
| Fluent Bit | ログ収集・フィルタリング (DaemonSet) | 50MB/ノード |
| Elasticsearch | ログ保存・全文検索 | 1GB RAM (開発モード) |
| Kibana | ログ可視化・KQLクエリ | 512MB RAM |

**学習ポイント**
- 転置インデックスの仕組みと検索クエリ (Query DSL / KQL)
- Fluent Bit のフィルタリング・ルーティング設定
- Kibana ダッシュボード作成

### 2-2. 分散トレーシング

| コンポーネント | 役割 |
|--------------|------|
| OpenTelemetry Collector | トレース・メトリクスの収集・変換 |
| Grafana Tempo | トレース保存・Grafana と統合 |

---

## Phase 3 — GitOps / CI/CD

### 3-1. ArgoCD

k3s に ArgoCD を導入し、このリポジトリを GitOps の起点にする。

```
[GitHub リポジトリ]
       |  (git push)
    ArgoCD  →  k3s クラスターへ自動同期
```

**学習ポイント**
- GitOps の思想 (Git を唯一の真実の源泉とする)
- Application / AppProject の管理
- Sync Policy / Health Check

### 3-2. Harbor (コンテナレジストリ)

プライベートの Docker レジストリを自前で運用する。

| 機能 | 内容 |
|------|------|
| プライベートレジストリ | 自作イメージの保管 |
| 脆弱性スキャン | Trivy との統合 |
| レプリケーション | 外部レジストリとの同期 |

---

## Phase 4 — セキュリティ・シークレット管理

### 4-1. HashiCorp Vault

| 用途 | 内容 |
|------|------|
| シークレット管理 | API キー・DB パスワードの動的発行 |
| PKI | 内部 CA として証明書を発行 |
| k3s 統合 | Vault Agent Injector でPodに自動注入 |

**学習ポイント**
- Static / Dynamic Secrets の違い
- PKI シークレットエンジン
- Kubernetes Auth Method

### 4-2. Keycloak (SSO / OIDC)

Proxmox VE・Grafana・ArgoCD・Kibana のログインを一元化する。

```
[Keycloak]
  ├── Proxmox VE  (OIDC)
  ├── Grafana     (OAuth2)
  ├── ArgoCD      (OIDC)
  └── Kibana      (OIDC / SAML)
```

---

## Phase 5 — ネットワーク・サービスメッシュ

### 5-1. Cilium

k3s のCNIを Cilium に変更し、eBPF ベースのネットワーク制御を学ぶ。

| 機能 | 内容 |
|------|------|
| eBPF | カーネルレベルのパケット処理 |
| Network Policy | L3/L4/L7 のトラフィック制御 |
| Hubble | ネットワークオブザーバビリティ |

### 5-2. Proxmox SDN

Proxmox の Software Defined Network 機能を有効化し、VXLAN ベースの仮想ネットワークを実験する。

| 機能 | 内容 |
|------|------|
| VNET | 仮想ネットワークの論理分離 |
| VXLAN | L2 over UDP のオーバーレイネットワーク |
| BGP 連携 | FRRouting との組み合わせ |

---

## Phase 6 — ポリシー管理・IaC テスト

| 技術 | 内容 |
|------|------|
| Kyverno | Kubernetes へのポリシー強制 (イメージタグ・リソース制限の強制など) |
| OPA / Gatekeeper | より柔軟なポリシーエンジン |
| Terratest | Terraform コードの Go による自動テスト |

---

## 技術スタック全体像 (完成形)

```
オブザーバビリティ
  ├── メトリクス: Prometheus + Grafana
  ├── ログ:      Fluent Bit + Elasticsearch + Kibana
  └── トレース:  OpenTelemetry + Grafana Tempo

GitOps / CI/CD
  ├── ArgoCD (k3s への自動デプロイ)
  └── Harbor (プライベートレジストリ)

セキュリティ
  ├── Vault (シークレット管理・PKI)
  └── Keycloak (SSO / OIDC)

ネットワーク
  ├── Cilium (k3s CNI + eBPF)
  └── Proxmox SDN (VXLAN 実験)

ポリシー
  └── Kyverno (Kubernetes ポリシー強制)
```

---

## リソース追加が必要な場合

現状のリソース (2ノード × 4スレッド / 16GB) は Phase 2〜3 までなら十分。
Phase 4 以降は以下の追加を検討する。

| 対策 | 内容 |
|------|------|
| RAM 増設 | 各ノード 16GB → 最大 (NUC5i3RYH は 16GB が上限のため既に最大) |
| 3台目のノード追加 | Ceph 導入が可能になり、真の HA ストレージを実現 |
| 外付けストレージ | USB3.0 接続の SSD を PBS 用に追加 |
