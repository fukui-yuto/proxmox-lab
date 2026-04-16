# cert-manager

TLS 証明書の自動発行・更新。homelab 内部 CA を使用して `*.homelab.local` に HTTPS を提供する。

## デプロイ

ArgoCD の App of Apps が自動で管理する。2つの Application に分割されている:

```
cert-manager        Wave 3  Helm チャート + CRD インストール
cert-manager-issuers Wave 4  ClusterIssuer / ルート CA (cert-manager の後に適用)
```

```
Helm chart : jetstack/cert-manager v1.14.5
Namespace  : cert-manager
```

> **重要**: cert-manager v1.14.x では CRD インストールに `installCRDs: true` を使用する。
> `crds.enabled: true` は v1.15+ 用のキーで、v1.14.x では無効。

## ClusterIssuer 構成

homelab 内部 CA は以下の3段階で構成される:

```
selfsigned-issuer (自己署名)
    └── homelab-root-ca (ルート CA 証明書, 10年有効)
            └── homelab-ca-issuer (CA ClusterIssuer)
                    └── *.homelab.local の証明書を発行
```

## Ingress への TLS 設定方法

既存サービスの Ingress に以下を追加するだけで証明書が自動発行される:

```yaml
# values.yaml の ingress 設定例
ingress:
  annotations:
    cert-manager.io/cluster-issuer: homelab-ca-issuer
  tls:
    - hosts:
        - myservice.homelab.local
      secretName: myservice-tls
```

## 発行済み証明書の確認

```bash
kubectl get certificate -A
kubectl get clusterissuer
```

## トラブルシューティング

### ClusterIssuer が Missing になる

cert-manager CRD が未インストールの場合に発生。`values-cert-manager.yaml` に
`installCRDs: true` が設定されているか確認する。

```bash
kubectl get crd | grep cert-manager
```

CRD が0件なら cert-manager app を再 sync する:
```
argocd app sync cert-manager
```

CRD が揃ったら cert-manager-issuers を sync する:
```
argocd app sync cert-manager-issuers
```

### cert-manager-issuers が OutOfSync のまま

Wave 順序の問題で cert-manager CRD の登録前に cert-manager-issuers の sync が走ると失敗する。
automated sync が自動でリトライするので数分待つか、手動で sync する:

```
argocd app sync cert-manager-issuers
```
