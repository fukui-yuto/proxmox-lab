# Trivy Operator ガイド

## 概要

Trivy Operator は Kubernetes クラスター内のコンテナイメージ・設定・RBAC を継続的にスキャンし、結果を CRD (Custom Resource) として k8s に保存するセキュリティスキャナー。

### スキャン対象

| スキャン種別 | CRD | 内容 |
|------------|-----|------|
| 脆弱性 | `VulnerabilityReport` | コンテナイメージの CVE |
| 設定監査 | `ConfigAuditReport` | Deployment/Pod のセキュリティ設定ミス |
| インフラ評価 | `InfraAssessmentReport` | ノード・クラスターの設定確認 |
| RBAC 評価 | `RbacAssessmentReport` | 過剰な権限の RBAC |
| 露出シークレット | `ExposedSecretReport` | コンテナ内の平文シークレット |

---

## スキャン結果の確認

```bash
# 脆弱性レポート一覧
kubectl get vulnerabilityreport -A

# 特定の namespace の詳細
kubectl get vulnerabilityreport -n my-namespace -o wide

# 高・致命的な脆弱性のみフィルタ
kubectl get vulnerabilityreport -A -o json | \
  jq '.items[] | select(.report.summary.criticalCount > 0 or .report.summary.highCount > 0) | .metadata.name'

# 設定監査レポート
kubectl get configauditreport -A

# RBAC 評価レポート
kubectl get rbacassessmentreport -A
```

---

## Harbor との統合

Harbor のプロジェクト設定でプッシュ時スキャンを有効化すると、
イメージプッシュ → Harbor スキャン → Trivy Operator クラスター内スキャンの二重チェックになる。

```
開発者 → docker push → Harbor (プッシュ時スキャン)
                              ↓
                    k8s デプロイ → Trivy Operator (実行時スキャン)
```

---

## Grafana ダッシュボード

Trivy Operator は Prometheus メトリクスを公開する。kube-prometheus-stack と統合されているため、
Grafana でスキャン結果を可視化できる。

インポート用ダッシュボード ID: `17813` (Trivy Operator Dashboard)

---

## Kyverno との統合例

Trivy の脆弱性レポートを Kyverno ポリシーで参照し、HIGH 以上の CVE があるイメージのデプロイをブロックする構成も可能。

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: block-vulnerable-images
spec:
  validationFailureAction: Enforce
  rules:
    - name: check-vulnerabilities
      match:
        resources:
          kinds: [Pod]
      verify:
        - imageReferences: ["*"]
          attestors:
            - entries:
                - keyless:
                    rekor:
                      url: https://rekor.sigstore.dev
```

---

## スキャン間隔の調整

homelab のリソースに合わせて `operator.scanJobTTL` で TTL を調整する。
デフォルトは 24h ごとに再スキャン。並列スキャン数は `concurrentScanJobsLimit: "3"` に制限済み。
