# cert-manager ガイド

## cert-manager とは

Kubernetes ネイティブな TLS 証明書管理ツール。
Certificate リソースを定義するだけで証明書の発行・更新を自動化する。

## homelab での証明書発行フロー

```
1. Ingress に cert-manager.io/cluster-issuer: homelab-ca-issuer を付与
        ↓
2. cert-manager が Certificate リソースを自動作成
        ↓
3. homelab-ca-issuer (内部 CA) が証明書を署名・発行
        ↓
4. 証明書が Secret に保存される
        ↓
5. Ingress が Secret から TLS 証明書を参照
        ↓
6. HTTPS でアクセス可能になる
```

## 内部 CA の仕組み

homelab では Let's Encrypt が使えない (`*.homelab.local` は公開ドメインでないため)。
代わりに自己署名のルート CA を cert-manager 自身に管理させる。

```
ClusterIssuer: selfsigned-issuer
  └── Certificate: homelab-root-ca (Secret: homelab-root-ca-secret)
        └── ClusterIssuer: homelab-ca-issuer
              └── 各サービスの TLS 証明書
```

ブラウザにルート CA (`homelab-root-ca-secret`) をインポートすると、
全サービスで証明書警告が出なくなる。

## ルート CA 証明書のエクスポート (ブラウザへのインポート用)

```bash
kubectl get secret homelab-root-ca-secret -n cert-manager \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > homelab-root-ca.crt
```

Windows へのインポート:
1. `homelab-root-ca.crt` をダブルクリック
2. 「証明書のインストール」→「ローカルコンピューター」
3. 「信頼されたルート証明機関」に配置

## Certificate リソースの直接作成

Ingress 経由でなく Secret に直接証明書を発行したい場合:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: my-cert
  namespace: my-namespace
spec:
  secretName: my-cert-secret
  duration: 8760h   # 1年
  renewBefore: 720h # 30日前に自動更新
  dnsNames:
    - myservice.homelab.local
  issuerRef:
    name: homelab-ca-issuer
    kind: ClusterIssuer
```

## Let's Encrypt への移行

将来的に公開ドメインを取得した場合は以下の ClusterIssuer を追加するだけ:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: your@email.com
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
      - http01:
          ingress:
            class: traefik
```

---

## ファイル構成と各ファイルのコード解説

### ファイル一覧

| ファイル | 役割 |
|---------|------|
| `values-cert-manager.yaml` | cert-manager Helm チャートのカスタム values。CRD インストールやリソース制限を設定 |
| `cluster-issuers.yaml` | 内部 CA チェーンの定義 (ClusterIssuer + ルート CA Certificate) |
| `README.md` | 運用手順・デプロイ方法・トラブルシューティング |
| `GUIDE.md` | 本ファイル。cert-manager の概念説明・学習用ドキュメント |

> ArgoCD では 2 つの Application に分割して管理される:
> - **cert-manager** (Wave 3): Helm チャート本体 (`values-cert-manager.yaml` を使用)
> - **cert-manager-issuers** (Wave 4): ClusterIssuer 定義 (`cluster-issuers.yaml` を使用)
>
> Wave を分けることで「CRD が先にインストールされ、その後 ClusterIssuer が作成される」順序を保証している。

---

### values-cert-manager.yaml の解説

このファイルは Helm チャート `jetstack/cert-manager` に渡すカスタム設定値。
Helm のデフォルト値を上書きして、homelab 環境に合わせた設定を行う。

```yaml
# CRD を Helm で管理する (v1.14.x では installCRDs を使用)
installCRDs: true
```

**`installCRDs: true`** は cert-manager が使用するカスタムリソース定義 (CRD) を Helm インストール時に自動で作成する設定。

CRD とは Kubernetes に「Certificate」「ClusterIssuer」などの新しいリソースタイプを教えるための定義ファイル。これがないと `kubectl apply -f cluster-issuers.yaml` をしても「そんなリソースは知らない」とエラーになる。

> **注意**: cert-manager v1.15 以降では `crds.enabled: true` に変更されたが、本環境は v1.14.x なので `installCRDs: true` を使用する。

---

```yaml
resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    cpu: 200m
    memory: 256Mi
```

**cert-manager controller (メインコンポーネント)** のリソース制限。

| フィールド | 意味 |
|-----------|------|
| `requests.cpu: 50m` | 最低限確保する CPU (50 ミリコア = 0.05 コア) |
| `requests.memory: 64Mi` | 最低限確保するメモリ (64 MiB) |
| `limits.cpu: 200m` | CPU 使用量の上限 (200 ミリコア = 0.2 コア) |
| `limits.memory: 256Mi` | メモリ使用量の上限 (256 MiB)。超過すると OOMKill される |

cert-manager controller は証明書の発行・更新を監視するメインプロセス。普段はほぼアイドル状態なので少ないリソースで十分動作する。

---

```yaml
webhook:
  resources:
    requests:
      cpu: 20m
      memory: 32Mi
    limits:
      cpu: 100m
      memory: 128Mi
```

**webhook** は Kubernetes API サーバーからのリクエストを受け取り、Certificate や ClusterIssuer リソースのバリデーション (検証) を行うコンポーネント。

例えば、不正な `issuerRef` を持つ Certificate を作成しようとすると、webhook が「そんな Issuer は存在しない」とリクエストを拒否してくれる。常時動作するが処理は軽いため、controller より少ないリソースで動く。

---

```yaml
cainjector:
  resources:
    requests:
      cpu: 20m
      memory: 64Mi
    limits:
      cpu: 100m
      memory: 256Mi
```

**cainjector** は CA バンドル (信頼する CA 証明書の一覧) を Kubernetes リソースに自動注入するコンポーネント。

具体的には、webhook の `ValidatingWebhookConfiguration` や `MutatingWebhookConfiguration` に CA 証明書を注入して、API サーバーが webhook との TLS 通信を信頼できるようにする。起動時にメモリを使うため `limits.memory` は controller と同じ 256Mi を確保している。

---

### cluster-issuers.yaml の解説

このファイルは homelab 内部 CA (認証局) チェーンを構築する 3 つのリソースを定義している。「鶏と卵」問題を解決するために 3 段階の構成になっている。

#### なぜ 3 段階必要なのか?

CA 証明書を発行するには「発行者 (Issuer)」が必要だが、最初の発行者は誰が作るのか? という問題がある。
解決策は「自分で自分を署名する (自己署名)」発行者をまず作り、そこからルート CA を発行し、そのルート CA を使って実際の証明書を発行する、という段階的な構成。

```
selfsigned-issuer (自分で自分に署名できる特殊な発行者)
    │
    │  ← この発行者を使って...
    ▼
homelab-root-ca (ルート CA 証明書を発行)
    │
    │  ← この CA 証明書を使って...
    ▼
homelab-ca-issuer (各サービスの TLS 証明書を発行する実際の発行者)
    │
    ▼
grafana.homelab.local, argocd.homelab.local, ... の証明書
```

---

#### リソース 1: selfsigned-issuer (ブートストラップ用自己署名 Issuer)

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
```

| フィールド | 説明 |
|-----------|------|
| `kind: ClusterIssuer` | クラスター全体で使える発行者 (namespace を問わない) |
| `metadata.name` | `selfsigned-issuer` という名前で他のリソースから参照される |
| `spec.selfSigned: {}` | 「自己署名」タイプ。発行する証明書を自分自身の秘密鍵で署名する |

**役割**: このリソースは「最初の 1 枚」であるルート CA 証明書を作るためだけに存在する。実際のサービス証明書の発行には使わない。自己署名証明書はブラウザに信頼されないため、直接使うと警告が出る。

---

#### リソース 2: homelab-root-ca (ルート CA 証明書)

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: homelab-root-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: homelab-root-ca
  secretName: homelab-root-ca-secret
  duration: 87600h   # 10 years
  renewBefore: 720h  # 30 days
  privateKey:
    algorithm: RSA
    size: 4096
  issuerRef:
    name: selfsigned-issuer
    kind: ClusterIssuer
```

| フィールド | 説明 |
|-----------|------|
| `kind: Certificate` | cert-manager に「証明書を発行してほしい」と依頼するリソース |
| `namespace: cert-manager` | cert-manager namespace に作成 (Secret もここに保存される) |
| `spec.isCA: true` | **重要**: この証明書を CA として使う (他の証明書を署名できる) ことを宣言 |
| `spec.commonName` | 証明書の CN (Common Name)。識別名として使われる |
| `spec.secretName` | 発行された証明書 (秘密鍵 + 公開鍵) が保存される Secret の名前 |
| `spec.duration: 87600h` | 証明書の有効期間 (87600 時間 = 10 年) |
| `spec.renewBefore: 720h` | 期限切れ 30 日前に自動更新を開始する |
| `spec.privateKey.algorithm: RSA` | RSA アルゴリズムを使用 |
| `spec.privateKey.size: 4096` | 4096 ビットの鍵長 (セキュリティ強度が高い) |
| `spec.issuerRef` | この証明書を署名する発行者 = `selfsigned-issuer` を指定 |

**役割**: homelab 全体の信頼の起点となるルート CA 証明書。この証明書をブラウザにインポートすると、ここから発行された全ての証明書が信頼される。

生成後、Secret `homelab-root-ca-secret` には以下が保存される:
- `tls.crt` - CA の公開証明書 (ブラウザにインポートするファイル)
- `tls.key` - CA の秘密鍵 (証明書の署名に使う。漏洩厳禁)
- `ca.crt` - CA チェーン (自己署名なので tls.crt と同じ)

---

#### リソース 3: homelab-ca-issuer (実際に証明書を発行する ClusterIssuer)

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: homelab-ca-issuer
spec:
  ca:
    secretName: homelab-root-ca-secret
```

| フィールド | 説明 |
|-----------|------|
| `kind: ClusterIssuer` | クラスター全体で使える発行者 |
| `metadata.name` | `homelab-ca-issuer` - 各 Ingress のアノテーションで指定する名前 |
| `spec.ca.secretName` | 署名に使う CA 証明書の Secret 名。リソース 2 で作成された Secret を参照 |

**役割**: 各サービス (Grafana, ArgoCD, Harbor など) の Ingress に `cert-manager.io/cluster-issuer: homelab-ca-issuer` アノテーションを付けると、この ClusterIssuer が自動的に TLS 証明書を発行する。

発行された証明書は `homelab-root-ca` によって署名されるため、ブラウザにルート CA をインポートしていれば全て信頼される。

---

#### 3 つのリソースの関係図 (まとめ)

```
┌─────────────────────────────────────────────────────────────┐
│  cluster-issuers.yaml                                       │
│                                                             │
│  ┌──────────────────┐                                       │
│  │ ClusterIssuer    │                                       │
│  │ selfsigned-issuer│──── selfSigned: {} (自分で署名)       │
│  └────────┬─────────┘                                       │
│           │ issuerRef で参照                                 │
│           ▼                                                 │
│  ┌──────────────────────┐    ┌─────────────────────────┐   │
│  │ Certificate          │───▶│ Secret                  │   │
│  │ homelab-root-ca      │    │ homelab-root-ca-secret  │   │
│  │ (isCA: true, 10年)   │    │ (tls.crt + tls.key)    │   │
│  └──────────────────────┘    └────────────┬────────────┘   │
│                                           │ secretName で参照│
│                                           ▼                 │
│  ┌──────────────────────┐                                   │
│  │ ClusterIssuer        │                                   │
│  │ homelab-ca-issuer    │──── ca.secretName で署名に利用    │
│  └────────┬─────────────┘                                   │
│           │                                                 │
└───────────┼─────────────────────────────────────────────────┘
            │ Ingress アノテーションで参照
            ▼
    各サービスの TLS 証明書が自動発行される
```

この構成により、新しいサービスを追加する際は Ingress に 1 行アノテーションを追加するだけで TLS 証明書が自動的に発行・更新される。cert-manager が証明書の有効期限を監視し、期限切れ前に自動で再発行してくれるため、運用者が証明書の更新を手動で行う必要がない。
