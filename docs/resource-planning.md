# リソース計画書 — 全Phase実装時のスペック試算

ロードマップ (roadmap.md) に記載した全サービスを実装した場合のリソース試算。

---

## 物理スペック

| | node01 | node02 | 合計 |
|--|--------|--------|------|
| CPU | 2C/4T (i3-5010U) | 2C/4T (i3-5010U) | **4C/8T** |
| RAM | 16GB | 16GB | **32GB** |
| Proxmox ホスト消費 | -1.5GB | -1.5GB | **使用可能 29GB** |

---

## 全サービス リソース試算

### 専用 VM / LXC

| サービス | vCPU | RAM | 対応 Phase |
|---------|------|-----|-----------|
| router-vm (VyOS) | 1 | 512MB | Phase 1 |
| dns-ct (Pi-hole) | 1 | 256MB | 既存 |
| k3s-master | 1 | 1GB | 既存 |
| k3s-worker01 | 1 | 2GB (**1GB→2GB に増設**) | 既存→拡張 |
| k3s-worker02 | 1 | 2GB (**1GB→2GB に増設**) | 既存→拡張 |
| monitoring LXC (Prometheus + Grafana) | 1 | 512MB | Phase 1 |
| PBS (Proxmox Backup Server) | 1 | 1GB | Phase 1 |
| Elasticsearch VM | 1 | 2GB | Phase 2 |
| Keycloak VM | 1 | 1GB | Phase 4 |
| **合計** | **9 vCPU** | **10.25GB** | |

### k3s 上で動くサービス (worker の RAM を消費)

| サービス | RAM目安 | 対応 Phase |
|---------|---------|-----------|
| Alertmanager | 128MB | Phase 1 |
| Fluent Bit (DaemonSet × 3ノード) | 150MB | Phase 2 |
| Kibana | 512MB | Phase 2 |
| OpenTelemetry Collector + Grafana Tempo | 512MB | Phase 2 |
| ArgoCD | 512MB | Phase 3 |
| Harbor | 1GB | Phase 3 |
| HashiCorp Vault | 256MB | Phase 4 |
| Cilium (DaemonSet) | 300MB | Phase 5 |
| Kyverno | 256MB | Phase 6 |
| **合計** | **~3.6GB** | |

---

## 判定

### RAM

| 項目 | 消費量 |
|------|--------|
| Proxmox ホスト × 2 | 3GB |
| 専用 VM / LXC 全サービス | 10.25GB |
| **合計必要量** | **約 13.25GB** |
| **物理 RAM 合計** | **32GB** |
| **余裕** | **約 19GB (60% 余り)** |

**→ 余裕で足りる**

### CPU

| 項目 | 数 |
|------|---|
| 物理スレッド合計 | 8T |
| 割り当て vCPU 合計 | 9 vCPU |
| オーバープロビジョニング | 1 vCPU 分 |

**→ 1スレッド分だけ超えるが実用上は問題なし**
全 VM が同時に 100% 使用することはないため、スケジューリングで吸収できる。

---

## 唯一のリスク: k3s ワーカーの RAM 不足

| | 現在 | 必要量 |
|-|------|--------|
| worker01 + worker02 合計 | 2GB | **約 4GB** |

Phase 2 以降で k3s 上に載せるサービスが増えると、現在の 1GB × 2 台では不足する。

### 対策 (ハードウェア追加不要)

**優先: worker の RAM を増やす**

Terraform の設定変更のみで対応可能。物理 RAM には十分な余裕がある。

```hcl
# terraform/main.tf
resource "proxmox_vm_qemu" "k3s_worker" {
  memory = 2048  # 1024 → 2048 に変更
}
```

**それでも足りない場合: worker を 1 台追加**

```hcl
# k3s-worker03 を追加定義
resource "proxmox_vm_qemu" "k3s_worker03" {
  name   = "k3s-worker03"
  memory = 2048
  cores  = 1
}
```

---

## 総合判定

| リソース | 判定 | 備考 |
|---------|------|------|
| RAM (全体) | ✅ 余裕あり | 約 60% 余り |
| CPU | ✅ 問題なし | 実使用率は低いため吸収可能 |
| k3s ワーカー RAM | ⚠️ 要増設 | Terraform 設定変更のみ (1GB → 2GB) |
| ハードウェア追加 | ✅ 不要 | 現状の NUC 2 台で全 Phase 実装可能 |

**ハードウェアを追加しなくても全 Phase を実装できる。**
k3s ワーカーの RAM を Terraform で 1GB → 2GB に変更するだけで対応できる。
