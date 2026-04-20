# ネットワークマップ

Proxmox ホームラボの全体ネットワーク構成図。

---

## ネットワークトポロジ

```
                        ┌─────────────────────────┐
                        │   インターネット / LAN    │
                        └────────────┬────────────┘
                                     │
                        ┌────────────┴────────────┐
                        │  ルーター / GW           │
                        │  192.168.210.254         │
                        └────────────┬────────────┘
                                     │
              ═══════════════════════════════════════════════  VLAN 1 (native)
              │          │           │           │          │  192.168.210.0/24
              │          │           │           │          │
     ┌────────┴───┐ ┌───┴────────┐ ┌┴──────────┐ ┌───────┴──────┐
     │ pve-node01 │ │ pve-node02 │ │ pve-node03 │ │ Raspberry Pi │
     │   .11      │ │   .12      │ │   .13      │ │   .55        │
     │ NUC5i3RYH  │ │ NUC5i3RYH  │ │ BOSGAME E2 │ │ 管理端末     │
     └──┬─────────┘ └──┬─────────┘ └──┬─────────┘ └──────────────┘
        │               │              │
        │  ┌────────┐   │  ┌────────┐  │  ┌────────┐
        ├──│ master │   ├──│worker03│  ├──│worker06│
        │  │ .21    │   ├──│ .24    │  ├──│ .27    │
        │  └────────┘   ├──│worker04│  ├──│worker07│
        │  ┌────────┐   │  │ .25    │  │  │ .28    │
        ├──│ dns-ct │   │  └────────┘  ├──│worker08│
        │  │ .53    │   └──│worker05│  │  │ .29    │
        │  └────────┘      │ .26    │  │  └────────┘
        │                  └────────┘  │
        │                              │
        ══════════════════════════════════  VLAN 20 (ストレージ)
        │               │                 192.168.212.0/24
   .212.11         .212.12
   (レプリケーション用)
```

---

## IP アドレスレンジ割り当て

### VLAN 1 - 管理 / VM / LAN (192.168.210.0/24)

| レンジ | 用途 |
|--------|------|
| 192.168.210.1 - .10 | ネットワーク機器 (予約) |
| 192.168.210.11 - .13 | Proxmox 物理ノード |
| 192.168.210.21 - .29 | k3s VM (マスター + ワーカー) |
| 192.168.210.53 | Pi-hole DNS (LXC) |
| 192.168.210.55 | Raspberry Pi 5 (管理端末) |
| 192.168.210.101 - .199 | (未使用 / DHCP プール) |
| 192.168.210.254 | デフォルトゲートウェイ |

### VLAN 20 - ストレージ (192.168.212.0/24)

| レンジ | 用途 |
|--------|------|
| 192.168.212.11 | pve-node01 ストレージ IF |
| 192.168.212.12 | pve-node02 ストレージ IF |

---

## 物理ノード

| ホスト名 | IP | MAC | スペック | 役割 |
|---------|-----|-----|---------|------|
| pve-node01 | 192.168.210.11 | - | NUC5i3RYH / i3-5010U / 16GB | Proxmox ノード (ZFS あり) |
| pve-node02 | 192.168.210.12 | - | NUC5i3RYH / i3-5010U / 16GB | Proxmox ノード |
| pve-node03 | 192.168.210.13 | - | BOSGAME E2 / Ryzen 5 3550H / 32GB | Proxmox ノード |
| Raspberry Pi 5 | 192.168.210.55 | 2c:cf:67:b5:b2:be | - | 管理端末 / corosync-qnetd / Ansible・Terraform 実行環境 |

---

## VM / コンテナ

| 名前 | VM ID | IP | CPU | RAM | Proxmox ノード | 役割 |
|------|-------|----|-----|-----|--------------|------|
| k3s-master | 201 | 192.168.210.21 | 2 | 6GB | pve-node01 | k3s コントロールプレーン (NoSchedule taint) |
| k3s-worker03 | 204 | 192.168.210.24 | 1 | 4GB | pve-node02 | k3s ワーカー |
| k3s-worker04 | 205 | 192.168.210.25 | 1 | 4GB | pve-node02 | k3s ワーカー |
| k3s-worker05 | 206 | 192.168.210.26 | 1 | 4GB | pve-node02 | k3s ワーカー |
| k3s-worker06 | 207 | 192.168.210.27 | 2 | 8GB | pve-node03 | k3s ワーカー |
| k3s-worker07 | 208 | 192.168.210.28 | 2 | 8GB | pve-node03 | k3s ワーカー |
| k3s-worker08 | 209 | 192.168.210.29 | 2 | 8GB | pve-node03 | k3s ワーカー |
| dns-ct | 101 | 192.168.210.53 | - | 512MB | pve-node01 | Pi-hole DNS (LXC) |

> **削除済みワーカー:** worker01 (VM 202 / .22), worker02 (VM 203 / .23), worker09 (VM 210 / .30), worker10 (VM 211 / .31) は削除済み。これらの VM ID・IP は現在使用されていない。

---

## VLAN 構成

| VLAN ID | 用途 | サブネット | 備考 |
|---------|------|-----------|------|
| 1 (native) | 管理 / VM / 既存 LAN | 192.168.210.0/24 | タグなし (デフォルト) |
| 20 | ストレージ / Proxmox レプリケーション | 192.168.212.0/24 | pve-node01 ↔ pve-node02 間 ZFS レプリケーション |

---

## k8s サービス (Traefik Ingress 経由)

全サービスは **192.168.210.25 (k3s-worker04)** 経由でアクセスする。

| FQDN | ポート | 用途 |
|------|--------|------|
| grafana.homelab.local | 80 | Grafana ダッシュボード |
| kibana.homelab.local | 80 | Kibana ログ閲覧 |
| elasticsearch.homelab.local | 80 | Elasticsearch API |
| argocd.homelab.local | 80 | ArgoCD UI |
| longhorn.homelab.local | 80 | Longhorn ストレージ UI |
| harbor.homelab.local | 80 | Harbor コンテナレジストリ |
| keycloak.homelab.local | 80 | Keycloak SSO |
| vault.homelab.local | 80 | Vault シークレット管理 |
| argo-workflows.homelab.local | 80 | Argo Workflows UI |
| alert-summarizer.homelab.local | 80 | アラートサマリー |
| minio.homelab.local | 80 | MinIO Console |
| minio-api.homelab.local | 80 | MinIO S3 API |

### なぜ .25 (worker04) を使うのか

`.24 (worker03)` ではなく `.25 (worker04)` を Ingress のエントリーポイントとして使用する理由:

- **Traefik Pod が worker03 (.24) 上で稼働している**
- Cilium の ExternalIP ローカルバックエンド問題により、Traefik Pod が稼働するノード自身の IP へ外部から接続すると不安定になる場合がある
- worker04 (.25) 経由であれば Cilium が正常にパケットをフォワードするため安定動作する

---

## DNS 構成

| 役割 | IP | 備考 |
|------|-----|------|
| プライマリ DNS | 192.168.210.53 | Pi-hole (dns-ct LXC) |
| デフォルトゲートウェイ | 192.168.210.254 | ルーター |

---

## Windows hosts ファイル設定

ブラウザから k8s サービスにアクセスするため、以下を `C:\Windows\System32\drivers\etc\hosts` に追加する:

```
192.168.210.25  grafana.homelab.local
192.168.210.25  kibana.homelab.local
192.168.210.25  elasticsearch.homelab.local
192.168.210.25  argocd.homelab.local
192.168.210.25  longhorn.homelab.local
192.168.210.25  harbor.homelab.local
192.168.210.25  keycloak.homelab.local
192.168.210.25  vault.homelab.local
192.168.210.25  argo-workflows.homelab.local
192.168.210.25  alert-summarizer.homelab.local
192.168.210.25  minio.homelab.local
192.168.210.25  minio-api.homelab.local
```
