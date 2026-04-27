# proxmox-lab

Intel NUC5i3RYH 2台 + BOSGAME E2 1台を使った自宅ラボの構築リポジトリ。
Proxmox VE クラスターの構築から k3s クラスター上の AIOps まで一元管理する。

---

## 構成概要

```
[Raspberry Pi 5]  192.168.210.55
  ├── corosync-qnetd  → 3ノードクラスターのクォーラム
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

## README を読む順番 — 一から構築する場合

> **この順番で README を読んで実行する。最小コマンドで構築できるよう整理している。**

### フェーズ 1: ハードウェアセットアップ

| # | README | 実行内容 |
|---|--------|---------|
| 1 | [scripts/README.md](scripts/README.md) | Raspberry Pi OS セットアップ → `bash raspi-setup.sh` → Proxmox を各ノードに USB インストール → SSH 鍵配布 |

### フェーズ 2: Proxmox クラスター構築

| # | README | 実行内容 |
|---|--------|---------|
| 2 | [ansible/README.md](ansible/README.md) | `ansible-playbook playbooks/00-bootstrap.yml -k` → `ansible-playbook playbooks/site.yml` |

### フェーズ 3: VM テンプレート・プロビジョニング

| # | README | 実行内容 |
|---|--------|---------|
| 3 | [packer/README.md](packer/README.md) | `packer build ubuntu-2404.pkr.hcl` (Ubuntu 24.04 テンプレート ID: 9000) |
| 4 | [terraform/README.md](terraform/README.md) | `terraform init` → `terraform apply` (VM 7台 + Pi-hole LXC 作成・k3s 構成) |

### フェーズ 4: k8s アプリデプロイ

| # | README | 実行内容 |
|---|--------|---------|
| 5 | [k8s/README.md](k8s/README.md) | Windows hosts ファイル設定・helm インストール確認 |
| 6 | [k8s/argocd/README.md](k8s/argocd/README.md) | `bash install.sh` → `bash register-apps.sh` |

`register-apps.sh` で全アプリの ArgoCD Application を一括登録。Sync Wave 0→15 の順に自動デプロイされる。

#### 全アプリ (ArgoCD 自動 Sync)

| Wave | アプリ | README |
|------|--------|--------|
| 0 | kyverno | [k8s/kyverno/README.md](k8s/kyverno/README.md) |
| 1 | kyverno-policies | ↑ 同上 |
| 2 | longhorn (分散永続ストレージ) | [k8s/longhorn/README.md](k8s/longhorn/README.md) |
| 3 | vault | [k8s/vault/README.md](k8s/vault/README.md) |
| 4 | monitoring (Prometheus + Grafana + Alertmanager) | [k8s/monitoring/README.md](k8s/monitoring/README.md) |
| 4 | argo-workflows | [k8s/argo-workflows/README.md](k8s/argo-workflows/README.md) |
| 4 | argo-events | [k8s/argo-events/README.md](k8s/argo-events/README.md) |
| 5 | harbor | [k8s/harbor/README.md](k8s/harbor/README.md) |
| 6 | keycloak | [k8s/keycloak/README.md](k8s/keycloak/README.md) |
| 7-9 | logging (Elasticsearch + Fluent Bit + Kibana) | [k8s/logging/README.md](k8s/logging/README.md) |
| 10-11 | tracing (Tempo + OpenTelemetry) | [k8s/tracing/README.md](k8s/tracing/README.md) |
| 12-15 | aiops (alerting / anomaly-detection / alert-summarizer / auto-remediation) | [k8s/aiops/README.md](k8s/aiops/README.md) |

### 日常運用

| README | 内容 |
|--------|------|
| [power/README.md](power/README.md) | クラスター起動・シャットダウン・アイドル自動停止 |
| [tests/README.md](tests/README.md) | Playwright E2E / API テスト実行 |

---

## k8s アプリ一覧

### アプリ一覧

| アプリ | URL | 説明 |
|--------|-----|------|
| ArgoCD | http://argocd.homelab.local | GitOps 管理コンソール |
| Longhorn | http://longhorn.homelab.local | 分散永続ストレージ管理UI |
| Grafana | http://grafana.homelab.local | メトリクス・AIOps ダッシュボード |
| Elasticsearch | http://elasticsearch.homelab.local | ログストレージ |
| Kibana | http://kibana.homelab.local | ログ閲覧・検索 |
| alert-summarizer | http://alert-summarizer.homelab.local | AlertManager → LLM サマリ → Grafana アノテーション |
| Vault | http://vault.homelab.local | シークレット管理 |
| Harbor | http://harbor.homelab.local | コンテナイメージレジストリ |
| Keycloak | http://keycloak.homelab.local | SSO / 認証基盤 (ArgoCD・Grafana・Harbor 連携済み) |
| Argo Workflows | http://argo-workflows.homelab.local | 自動修復ワークフロー実行履歴 |

### アクセス情報

| アプリ | ユーザー | 初期パスワード |
|--------|---------|--------------|
| ArgoCD | `admin` | `Argocd12345` |
| Grafana | `admin` | `changeme` |
| Harbor | `admin` | `Harbor12345` |
| Keycloak | `admin` | `Keycloak12345` |
| Vault | `admin` | `Vault12345` |

> Windows hosts ファイルへの追記は [k8s/README.md](k8s/README.md) を参照。

---

## デプロイされる VM / コンテナ

| 名前 | VM ID | 種別 | IP | Proxmox ノード | 用途 |
|------|-------|------|----|--------------|------|
| k3s-master | 201 | VM | 192.168.210.21 | pve-node03 | k3s コントロールプレーン (NoSchedule) |
| k3s-worker03 | 204 | VM | 192.168.210.24 | pve-node02 | k3s ワーカー |
| k3s-worker04 | 205 | VM | 192.168.210.25 | pve-node02 | k3s ワーカー |
| k3s-worker05 | 206 | VM | 192.168.210.26 | pve-node02 | k3s ワーカー |
| k3s-worker06 | 207 | VM | 192.168.210.27 | pve-node03 | k3s ワーカー |
| k3s-worker07 | 208 | VM | 192.168.210.28 | pve-node03 | k3s ワーカー |
| k3s-worker09 | 210 | VM | 192.168.210.30 | pve-node01 | k3s ワーカー |
| k3s-worker10 | 211 | VM | 192.168.210.31 | pve-node01 | k3s ワーカー |
| k3s-worker11 | 212 | VM | 192.168.210.32 | pve-node01 | k3s ワーカー |
| dns-ct | 101 | LXC | 192.168.210.53 | pve-node03 | Pi-hole (DNS) |

> worker01 (202), worker02 (203), worker08 (209) は削除済み。

---

## リポジトリ構成

```
proxmox-lab/
├── scripts/          # ★ Step 1: Raspberry Pi セットアップ・WoL スクリプト
├── ansible/          # ★ Step 2: Proxmox クラスター構築 Playbook
├── packer/           # ★ Step 3: Ubuntu 24.04 VM テンプレートビルド
├── terraform/        # ★ Step 4: VM / LXC プロビジョニング・k3s 構成
├── k8s/              # ★ Step 5: k3s クラスター上のアプリ管理
│   ├── argocd/           # GitOps 管理基盤 (install.sh + register-apps.sh)
│   ├── kyverno/          # ポリシーエンジン
│   ├── monitoring/       # Prometheus + Grafana + Alertmanager
│   ├── logging/          # Elasticsearch + Fluent Bit + Kibana
│   ├── vault/            # シークレット管理
│   ├── harbor/           # コンテナレジストリ
│   ├── keycloak/         # SSO / 認証基盤
│   ├── tracing/          # 分散トレーシング (Tempo + OpenTelemetry)
│   ├── argo-workflows/   # ワークフローエンジン
│   ├── argo-events/      # イベント駆動トリガー
│   └── aiops/            # AIOps (予測アラート・異常検知・LLM サマリ・自動修復)
├── power/            # クラスター起動・シャットダウン管理
├── tests/            # Playwright E2E / API テスト
└── docs/             # 設計・運用ドキュメント
    ├── design.md            # ハードウェア・ネットワーク・HA・構築手順・運用
    ├── network-map.md       # 全 IP・VLAN・サービスの一覧マップ
    ├── troubleshooting.md   # 既知の障害と復旧手順
    ├── disaster-recovery.md # 障害シナリオ別 DR ガイド
    ├── glossary.md          # 用語集 (初学者向け)
    └── proxmox-sdn-guide.md # Proxmox SDN ガイド
```

---

## 使用技術

| カテゴリ | 技術 |
|---------|------|
| ハイパーバイザー | Proxmox VE 8.x |
| OS | Debian 12 (Proxmox) / Ubuntu 24.04 (VM) |
| ストレージ | ZFS + Proxmox Replication |
| クォーラム | Corosync QDevice (Raspberry Pi) |
| 構成管理 | Ansible |
| インフラ管理 | Terraform (bpg/proxmox provider) |
| VM テンプレート | Packer |
| コンテナオーケストレーション | k3s |
| GitOps | ArgoCD |
| ポリシーエンジン | Kyverno |
| 監視 | Prometheus + Grafana + Alertmanager |
| ログ | Elasticsearch + Fluent Bit + Kibana |
| シークレット管理 | HashiCorp Vault |
| コンテナレジストリ | Harbor |
| SSO | Keycloak (OIDC) |
| 分散トレーシング | Grafana Tempo + OpenTelemetry |
| 異常検知 | ADTK (Python) + Prometheus Pushgateway |
| LLM サマリ | Claude API (claude-haiku-4-5) |
| イベント駆動 | Argo Events + Argo Workflows |
| テスト | Playwright (E2E / API) |

構築手順 (最小コマンド数)

# 1. Raspi
```
bash raspi-setup.sh
```

# 2. Ansible
```
ansible-playbook playbooks/00-bootstrap.yml -k
ansible-playbook playbooks/site.yml
```

# 3. Packer
```
packer build ubuntu-2404.pkr.hcl
```

# 4. Terraform
```
terraform apply
```

# 5. k8s (ArgoCD + 全アプリ)
```
bash k8s/argocd/install.sh
bash k8s/argocd/register-apps.sh
```