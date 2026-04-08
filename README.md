# proxmox-lab

Intel NUC5i3RYH 2台 + BOSGAME E2 1台を使った自宅ラボの構築リポジトリ。
Proxmox VE クラスターの構築から k3s クラスター上の AIOps まで一元管理する。

---

## 構成概要

```
[Raspberry Pi 5]  192.168.210.55
  ├── corosync-qnetd  → 2ノードクラスターのクォーラム
  └── Ansible / Terraform / Packer 実行環境

[pve-node01]  192.168.210.11  (NUC5i3RYH / Intel Core i3-5010U / 16GB RAM)
[pve-node02]  192.168.210.12  (NUC5i3RYH / Intel Core i3-5010U / 16GB RAM)
[pve-node03]  192.168.210.13  (BOSGAME E2 / AMD Ryzen 5 3550H / 32GB RAM)
  └── Proxmox VE 8.x クラスター "homelab"
        └── k3s クラスター (master × 1 + worker × 6)
```

## ネットワーク

| VLAN | 用途 | サブネット |
|------|------|-----------|
| 1 (native) | 管理 / VM / 既存 LAN | 192.168.210.0/24 |
| 20 | ストレージ / レプリケーション | 192.168.212.0/24 |

---

## 構築の流れ

| ステップ | 内容 | 手順 |
|---------|------|------|
| 1 | Raspberry Pi セットアップ・Proxmox インストール | [scripts/README.md](scripts/README.md) |
| 2 | Ansible でクラスター構築 | [ansible/README.md](ansible/README.md) |
| 3 | Packer で VM テンプレートをビルド | [packer/README.md](packer/README.md) |
| 4 | Terraform で VM デプロイ・k3s クラスター構成 | [terraform/README.md](terraform/README.md) |
| 5 | ArgoCD で k8s アプリをデプロイ | [k8s/argocd/README.md](k8s/argocd/README.md) |

日常運用 (起動・シャットダウン) は [power/README.md](power/README.md) を参照。

---

## リポジトリ構成

```
proxmox-lab/
├── ansible/                    # Proxmox ホスト OS の設定管理
│   ├── README.md               # ★ Step 2: クラスター構築手順
│   ├── inventory/hosts.yml
│   └── playbooks/
├── packer/                     # VM テンプレートのビルド
│   ├── README.md               # ★ Step 3: テンプレートビルド手順
│   └── ubuntu-2404.pkr.hcl
├── terraform/                  # VM / LXC のプロビジョニング
│   ├── README.md               # ★ Step 4: VM/CT デプロイ手順
│   └── main.tf
├── k8s/                        # k3s クラスター上のアプリ管理
│   ├── README.md               # k3s アプリデプロイ概要
│   ├── argocd/                 # ★ Step 5: GitOps 管理 (全アプリの起点)
│   ├── monitoring/             # Prometheus + Grafana
│   ├── logging/                # Elasticsearch + Fluent Bit + Kibana
│   ├── kyverno/                # ポリシーエンジン
│   ├── vault/                  # シークレット管理
│   ├── harbor/                 # コンテナレジストリ
│   ├── keycloak/               # SSO / 認証基盤
│   ├── tracing/                # 分散トレーシング (Tempo + OpenTelemetry)
│   ├── argo-workflows/         # ワークフローエンジン
│   ├── argo-events/            # イベント駆動トリガー
│   └── aiops/                  # AIOps (予測アラート・異常検知・自動修復)
│       ├── README.md           # AIOps デプロイ手順
│       ├── GUIDE.md            # AIOps 概念ガイド
│       ├── alerting/           # 予測・トレンド型アラートルール
│       ├── anomaly-detection/  # ログ異常検知 CronJob
│       ├── alert-summarizer/   # アラート Grafana 記録 Pod
│       └── auto-remediation/   # Argo Events/Workflows 自動修復
├── tests/                      # Playwright E2E / API テスト
│   ├── README.md               # テスト実行手順
│   ├── e2e/                    # ブラウザ E2E テスト
│   └── api/                    # HTTP API テスト
├── scripts/                    # 補助スクリプト
│   └── README.md               # ★ Step 1: Raspberry Pi セットアップ手順
├── power/                      # クラスター起動・シャットダウン管理
│   └── README.md
└── docs/
    ├── design.md               # 設計書
    └── runbook.md              # 日常運用
```

---

## k8s アプリ一覧

### 常時起動

| アプリ | URL | 説明 |
|--------|-----|------|
| ArgoCD | http://argocd.homelab.local | GitOps 管理コンソール |
| Grafana | http://grafana.homelab.local | メトリクス・AIOps ダッシュボード |
| Kibana | http://kibana.homelab.local | ログ閲覧・検索 |

### AIOps コンポーネント

| コンポーネント | URL | 説明 |
|--------------|-----|------|
| Log Anomaly Detection | Grafana > Dashboards | ログ異常スコア・Namespace/Pod 別内訳 |
| alert-summarizer | http://alert-summarizer.homelab.local | AlertManager → Grafana アノテーション記録 |
| Argo Workflows | http://argo-workflows.homelab.local | 自動修復ワークフロー実行履歴 |

### オンデマンド起動

| アプリ | URL | 説明 |
|--------|-----|------|
| Harbor | http://harbor.homelab.local | コンテナイメージレジストリ |
| Vault | http://vault.homelab.local | シークレット管理 |
| Keycloak | http://keycloak.homelab.local | SSO / 認証基盤 |

---

## デプロイされる VM / コンテナ

| 名前 | 種別 | IP | 用途 |
|------|------|----|------|
| k3s-master | VM | 192.168.210.21 | k3s マスター (pve-node01) |
| k3s-worker01 | VM | 192.168.210.22 | k3s ワーカー (pve-node01) |
| k3s-worker03 | VM | 192.168.210.24 | k3s ワーカー (pve-node02) |
| k3s-worker04 | VM | 192.168.210.25 | k3s ワーカー (pve-node02) |
| k3s-worker05 | VM | 192.168.210.26 | k3s ワーカー (pve-node02) |
| k3s-worker06 | VM | 192.168.210.27 | k3s ワーカー (pve-node03) |
| k3s-worker07 | VM | 192.168.210.28 | k3s ワーカー (pve-node03) |
| dns-ct | LXC | 192.168.210.53 | Pi-hole (DNS) |

---

## 使用技術

| カテゴリ | 技術 |
|---------|------|
| ハイパーバイザー | Proxmox VE 8.x |
| OS | Debian 12 (Proxmox) / Ubuntu 24.04 (VM) |
| ストレージ | ZFS + Proxmox Replication |
| クォーラム | Corosync QDevice |
| 構成管理 | Ansible |
| インフラ管理 | Terraform (bpg/proxmox) |
| テンプレート | Packer |
| コンテナオーケストレーション | k3s |
| GitOps | ArgoCD |
| 監視 | Prometheus + Grafana |
| ログ | Elasticsearch + Fluent Bit + Kibana |
| 異常検知 | ADTK (Python) + Prometheus Pushgateway |
| イベント駆動 | Argo Events + Argo Workflows |
| テスト | Playwright (E2E / API) |
