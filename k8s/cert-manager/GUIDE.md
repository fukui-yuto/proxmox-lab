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
