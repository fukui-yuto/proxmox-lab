# Harbor 詳細ガイド — プライベートコンテナレジストリ

## このツールが解決する問題

Kubernetes でアプリを動かすには Docker イメージが必要。
デフォルトでは Docker Hub からイメージを取得するが、いくつかの問題がある:

| 問題 | 内容 |
|------|------|
| Rate Limit | Docker Hub は無料プランで pull 回数に制限がある |
| 外部依存 | インターネットが切れるとイメージを取得できない |
| セキュリティ | 自作のアプリイメージを Docker Hub に上げたくない |
| スキャン | イメージの脆弱性を自動チェックしたい |

Harbor はラボ内にプライベートなレジストリを構築することでこれらを解決する。

---

## コンテナレジストリとは

コンテナイメージを保存・配信するサービス。Git でコードを管理するように、イメージを管理する。

```
開発者:
  docker build -t myapp:1.0.0 .     ← イメージをビルド
  docker push harbor.homelab.local/homelab/myapp:1.0.0  ← Harbor に保存

Kubernetes:
  image: harbor.homelab.local/homelab/myapp:1.0.0       ← Harbor から取得
```

---

## Harbor のコンポーネント

```
┌────────────────────────────────────────────────────┐
│  Harbor                                            │
│                                                    │
│  Portal (Web UI)  ← ブラウザで操作                  │
│  Core API         ← REST API サーバー               │
│  Registry         ← イメージの実体を保存             │
│  Job Service      ← バックグラウンドジョブ処理        │
│  Trivy            ← 脆弱性スキャンエンジン           │
│  PostgreSQL       ← メタデータ (内蔵)               │
│  Redis            ← キャッシュ (内蔵)               │
└────────────────────────────────────────────────────┘
```

### Trivy とは

**コンテナイメージの脆弱性スキャナー**。Aqua Security が開発したOSS。
OS パッケージ、言語ライブラリ (npm, pip, gem 等) の脆弱性を検出する。

```
イメージ push → Trivy が自動スキャン → 脆弱性レポート生成
                                         ↓
                               HIGH: 2件, CRITICAL: 0件 など
```

CVE (Common Vulnerabilities and Exposures) データベースを参照して脆弱性を検出する。

---

## Harbor の主要概念

### Project (プロジェクト)

イメージを管理する単位。アクセス制御の境界になる。

```
harbor.homelab.local/
├─ homelab/          ← Project: homelab
│   ├─ nginx:1.25.3
│   ├─ myapp:1.0.0
│   └─ myapp:2.0.0
└─ library/          ← Project: library (デフォルト・パブリック)
    └─ postgres:15
```

| アクセスレベル | 内容 |
|--------------|------|
| Private | 認証したユーザーのみ push/pull 可能 |
| Public | 認証なしで pull 可能 |

### Robot Account (ロボットアカウント)

CI/CD パイプラインや k3s ノードが Harbor に認証するための専用アカウント。
通常の人間ユーザーとは分離して管理できる。

```
CI/CD パイプライン → Robot Account で認証 → Harbor にイメージ push
k3s ノード         → Robot Account で認証 → Harbor からイメージ pull
```

### Replication (レプリケーション)

Harbor 間や Docker Hub からイメージを自動同期する機能。

```
Docker Hub の nginx:latest → Harbor に自動ミラー
               ↓ (定期実行)
harbor.homelab.local/proxy/nginx:latest として利用可能
```

---

## イメージのライフサイクル

```
1. ビルド
   docker build -t myapp:1.0.0 .

2. タグ付け
   docker tag myapp:1.0.0 harbor.homelab.local/homelab/myapp:1.0.0

3. Harbor にプッシュ
   docker push harbor.homelab.local/homelab/myapp:1.0.0

4. Trivy が自動スキャン
   → 脆弱性レポートが Harbor UI に表示される

5. k3s がプル
   image: harbor.homelab.local/homelab/myapp:1.0.0
```

---

## k3s の insecure registry 設定

このラボでは Harbor を HTTP (TLS なし) で運用している。
k3s はデフォルトで HTTPS のみ許可するため、`registries.yaml` で設定が必要。

```yaml
# /etc/rancher/k3s/registries.yaml (各ノードに配置)
mirrors:
  harbor.homelab.local:
    endpoint:
      - "http://harbor.homelab.local"
```

**なぜ HTTP なのか:**
- ホームラボでは自己署名証明書の管理が煩雑
- 外部に公開しないプライベートネットワーク内なので HTTP で許容している
- 本番環境では必ず HTTPS を使うこと

---

## Trivy スキャン結果の見方

Harbor UI でイメージの Trivy スキャン結果を確認できる。

```
Projects → homelab → Repositories → myapp → Tags → 1.0.0 → Vulnerabilities

┌────────────────────────────────────────────────────┐
│ Severity │ CVE ID        │ Package │ Fixed Version │
├────────────────────────────────────────────────────┤
│ CRITICAL │ CVE-2023-xxxx │ openssl │ 3.0.8         │ ← 要対応
│ HIGH     │ CVE-2023-yyyy │ libc    │ 2.37-1        │ ← 要確認
│ MEDIUM   │ CVE-2023-zzzz │ curl    │ Not fixed     │ ← 様子見
│ LOW      │ CVE-2023-wwww │ bash    │ -             │ ← 無視可
└────────────────────────────────────────────────────┘
```

**対応方針:**
- **CRITICAL**: すぐにベースイメージを更新する
- **HIGH**: 計画的に対応する
- **MEDIUM/LOW**: リスクを評価して判断

---

## Garbage Collection (ガベージコレクション)

古いイメージが蓄積するとディスクが枯渇する。Harbor の GC 機能で不要なイメージを削除できる。

```
Harbor UI → Administration → Garbage Collection → GC Now
```

**注意:** GC 中は Harbor が一時的に使用不能になる。

---

## よく使うコマンド

```bash
# Harbor Pod の状態確認
kubectl get pods -n harbor

# Harbor のログ確認
kubectl logs -n harbor -l component=core --tail=50

# Harbor の PVC 確認 (ディスク使用量)
kubectl get pvc -n harbor

# イメージの手動スキャン (CLI)
curl -u admin:Harbor12345 \
  -X POST \
  http://harbor.homelab.local/api/v2.0/projects/homelab/repositories/myapp/artifacts/1.0.0/scan
```

---

## Docker コマンドリファレンス

```bash
# Harbor にログイン
docker login harbor.homelab.local -u admin -p Harbor12345

# イメージをビルドして Harbor に push
docker build -t harbor.homelab.local/homelab/myapp:1.0.0 .
docker push harbor.homelab.local/homelab/myapp:1.0.0

# Harbor からイメージを pull
docker pull harbor.homelab.local/homelab/myapp:1.0.0

# イメージ一覧 (API)
curl -u admin:Harbor12345 \
  http://harbor.homelab.local/api/v2.0/projects/homelab/repositories
```

---

## トラブルシューティング

### docker push で `http: server gave HTTP response to HTTPS client`

Docker デーモンの insecure-registries 設定が必要。

```json
// /etc/docker/daemon.json (Linux) または
// Docker Desktop → Settings → Docker Engine
{
  "insecure-registries": ["harbor.homelab.local"]
}
```

### k3s がイメージを pull できない

```bash
# ノードの registries.yaml を確認
ssh ubuntu@192.168.210.22 cat /etc/rancher/k3s/registries.yaml

# k3s-agent を再起動
ssh ubuntu@192.168.210.22 sudo systemctl restart k3s-agent
```

### Harbor が起動しない (PostgreSQL の PVC が原因)

```bash
# PVC の状態確認
kubectl get pvc -n harbor

# PVC が Pending → StorageClass の確認
kubectl describe pvc -n harbor harbor-database
```
