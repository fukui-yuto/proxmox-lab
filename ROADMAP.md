# Homelab 実装ロードマップ

今後追加予定のサービス・技術をタスクとしてまとめたもの。

---

## 優先度: 高 (基盤安定化)

- [ ] **cert-manager** — TLS 証明書の自動発行・更新
  - Let's Encrypt or 自己署名 CA で `*.homelab.local` を HTTPS 化
  - Vault との統合 (PKI Secrets Engine) も検討
  - Wave: 3 (vault の直後)

- [ ] **Velero** — k8s リソースと PVC のバックアップ・DR
  - バックアップ先は MinIO (下記) を使用
  - 定期バックアップ (CronJob) + ArgoCD 連携
  - Wave: 4 (longhorn の後)

- [ ] **MinIO** — S3 互換オブジェクトストレージ
  - Velero のバックアップ先
  - Harbor の外部ストレージとしても利用可能
  - ML データレイク用途 (aiops との連携)
  - Wave: 3

---

## 優先度: 中 (機能拡張)

- [ ] **Argo Rollouts** — プログレッシブデリバリー
  - ArgoCD と統合してカナリア / Blue-Green デプロイを実現
  - 現状の ArgoCD は全量切り替えのみ → 段階的リリースが可能になる
  - Wave: 4 (argo-workflows と同列)

- [ ] **KEDA** — イベント駆動オートスケーリング
  - Prometheus メトリクス / Kafka / カスタムメトリクスで Pod をスケール
  - aiops-auto-remediation と組み合わせて動的スケーリングを自動修復に活用
  - Wave: 4

- [ ] **Falco** — ランタイム脅威検知
  - syscall レベルの異常検知 (Kyverno は admission 時のみ → 補完関係)
  - アラートを Alertmanager / aiops-alerting に連携
  - Wave: 4

- [ ] **Trivy Operator** — コンテナイメージ脆弱性スキャン
  - CRD で継続的にスキャン結果を k8s リソースとして管理
  - Harbor との統合でプッシュ時スキャンも設定
  - Wave: 5

---

## 優先度: 低 (発展・学習)

- [ ] **Cilium + Hubble** — eBPF ベース CNI + ネットワーク可観測性
  - 現行 CNI からの移行コストは高いが学習価値は最大
  - Hubble UI でネットワークフローを可視化
  - L7 ポリシー (HTTP/gRPC レベル) の制御が可能になる
  - ※ CNI 移行は全 Pod 再起動が必要。メンテナンスウィンドウを確保

- [ ] **LitmusChaos** — カオスエンジニアリング
  - Pod/Node 障害を意図的に注入して自動修復 (aiops-auto-remediation) の動作を検証
  - 環境が安定してから導入

- [ ] **Backstage** — 開発者ポータル / サービスカタログ
  - 全サービスのドキュメント・CI/CD・ログへのワンストップアクセス
  - チームが増えた際に価値が出る

- [ ] **Crossplane** — Kubernetes CRD でインフラを管理
  - Terraform の代替として Proxmox VM を k8s リソースとして宣言的管理
  - 長期的な方向性として検討

---

## 実装順序 (推奨)

```
1. MinIO           → オブジェクトストレージ基盤を先に用意
2. cert-manager    → HTTPS 化 (基盤として早急に必要)
3. Velero          → MinIO をバックアップ先に設定
4. Argo Rollouts   → ArgoCD の自然な拡張
5. KEDA            → AIOps との統合
6. Falco           → セキュリティ強化
7. Trivy Operator  → イメージスキャン継続化
8. Cilium + Hubble → CNI 移行 (メンテナンスウィンドウ要)
9. LitmusChaos     → カオステスト
10. Backstage      → ポータル整備
11. Crossplane     → Terraform 移行検討
```

---

## ArgoCD Sync Wave 追加計画

| Wave | 追加予定アプリ |
|------|--------------|
| 3 | minio, cert-manager |
| 4 | velero, argo-rollouts, keda, falco |
| 5 | trivy-operator |
| TBD | cilium (CNI 移行), litmus-chaos, backstage, crossplane |
