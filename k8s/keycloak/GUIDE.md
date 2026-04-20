# Keycloak 詳細ガイド — アイデンティティ・アクセス管理 (IAM)

## このツールが解決する問題

ラボに複数のツール (Grafana, ArgoCD, Harbor, Kibana...) があると、それぞれに別のパスワードが必要になる。

```
問題:
  Grafana    → ユーザー/パスワード A
  ArgoCD     → ユーザー/パスワード B
  Harbor     → ユーザー/パスワード C
  Kibana     → ユーザー/パスワード D
  → ツールが増えるほどパスワード管理が大変

解決:
  Keycloak でログイン → 全ツールにアクセス可能 (SSO)
```

---

## 認証の基礎知識

### 認証 (Authentication) と 認可 (Authorization)

| 概念 | 意味 | 例 |
|------|------|----|
| 認証 (AuthN) | 「あなたは誰ですか？」 | ユーザー名/パスワードでの本人確認 |
| 認可 (AuthZ) | 「何ができますか？」 | admin ロールなら全操作可、viewer なら読み取りのみ |

Keycloak は主に **認証** を担当し、認可は各アプリが担当する。

### OAuth2 と OIDC

**OAuth2:** 「アプリに代わって別のサービスにアクセスする権限を委任する」仕組み。

```
例: Grafana が Keycloak に「このユーザーを認証してください」と委任する
ユーザーはパスワードを Grafana に渡さず、Keycloak に渡す
```

**OIDC (OpenID Connect):** OAuth2 の上に「ユーザー情報 (ID) の取得」を追加した仕様。
Keycloak は OIDC プロバイダーとして動作する。

---

## Keycloak の主要概念

### Realm (レルム)

**テナント/環境の区切り**。Realm ごとにユーザー・クライアント・設定を完全に分離できる。

```
Keycloak
├─ master realm (Keycloak 自身の管理用。通常は触らない)
└─ homelab realm (このラボ用)
    ├─ Users: yuto, admin, ...
    ├─ Clients: grafana, argocd, harbor, ...
    └─ Roles: admin, viewer, ...
```

### Client (クライアント)

**Keycloak に認証を委任するアプリ**。Grafana や ArgoCD が Client として登録される。

```
Client 設定の例 (Grafana):
  Client ID: grafana
  Client Type: OpenID Connect
  Root URL: http://grafana.homelab.local
  Valid Redirect URIs: http://grafana.homelab.local/login/generic_oauth
  Client Secret: xxxxxxxxxxxxxxxx  ← Grafana の設定に記載する
```

### Client Secret

Client と Keycloak 間の認証に使うパスワード。
Grafana の設定ファイルに記載し、「このリクエストは本物の Grafana からのものだ」と Keycloak が確認する。

### User (ユーザー)

Keycloak で管理するユーザー。Realm ごとに独立している。

### Role (ロール)

ユーザーの権限グループ。

```
homelab realm のロール例:
  admin  → Grafana で Admin 権限
  viewer → Grafana で Viewer 権限 (読み取りのみ)
```

---

## SSO のログインフロー

Grafana を例にした OIDC ログインの流れ:

```
1. ユーザーが http://grafana.homelab.local にアクセス
        ↓
2. Grafana が「Keycloak でログインしてください」にリダイレクト
   → http://keycloak.homelab.local/realms/homelab/protocol/openid-connect/auth
        ↓
3. ユーザーが Keycloak のログイン画面でユーザー名/パスワードを入力
        ↓
4. Keycloak が認証 OK → Grafana に Authorization Code を渡す
        ↓
5. Grafana が Authorization Code を使って Access Token を取得
        ↓
6. Grafana が Access Token でユーザー情報 (名前、メール、ロール) を取得
        ↓
7. ユーザーが Grafana にログイン完了
```

このフローの間、ユーザーは Grafana にパスワードを渡していない。
Keycloak にだけパスワードを渡している。

---

## JWT トークン

OIDC では認証情報を **JWT (JSON Web Token)** として渡す。
JWT は Base64 でエンコードされた JSON で、3つのパートに分かれる。

```
eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ5dXRvIiwicm9sZXMiOlsiYWRtaW4iXX0.xxxxx
         ↑ Header          ↑ Payload (ユーザー情報)              ↑ Signature
```

**Payload の例 (デコード後):**
```json
{
  "sub": "user-id-123",           ← ユーザーの一意ID
  "preferred_username": "yuto",   ← ユーザー名
  "email": "yuto@example.com",    ← メール
  "roles": ["admin"],             ← ロール
  "exp": 1735689600,              ← 有効期限
  "iss": "http://keycloak.homelab.local/realms/homelab"  ← 発行者
}
```

Grafana はこの JWT を検証し、`roles` フィールドに `admin` があれば Admin として扱う。

---

## Grafana との OIDC 連携設定

`k8s/monitoring/values.yaml` に以下を追加する:

```yaml
grafana:
  grafana.ini:
    auth.generic_oauth:
      enabled: true
      name: Keycloak
      allow_sign_up: true
      client_id: grafana
      client_secret: <Keycloak で生成した Client Secret>
      scopes: openid email profile roles
      auth_url: http://keycloak.homelab.local/realms/homelab/protocol/openid-connect/auth
      token_url: http://keycloak.homelab.local/realms/homelab/protocol/openid-connect/token
      api_url: http://keycloak.homelab.local/realms/homelab/protocol/openid-connect/userinfo
      # Keycloak の roles が admin なら Grafana の Admin に対応
      role_attribute_path: contains(roles[*], 'admin') && 'Admin' || 'Viewer'
```

---

## ArgoCD との OIDC 連携設定

`k8s/argocd/values-argocd.yaml` に以下を追加する:

```yaml
configs:
  cm:
    oidc.config: |
      name: Keycloak
      issuer: http://keycloak.homelab.local/realms/homelab
      clientID: argocd
      clientSecret: <Keycloak で生成した Client Secret>
      requestedScopes: ["openid", "profile", "email", "groups"]
  rbac:
    policy.csv: |
      g, admin, role:admin
      g, viewer, role:readonly
```

---

## Keycloak の OIDC エンドポイント

Keycloak は以下の URL でエンドポイントを自動公開する。
各アプリの OIDC 設定に使用する。

```
# Well-known エンドポイント (全設定が載っている)
http://keycloak.homelab.local/realms/homelab/.well-known/openid-configuration

# 主要エンドポイント
認証:      http://keycloak.homelab.local/realms/homelab/protocol/openid-connect/auth
トークン:  http://keycloak.homelab.local/realms/homelab/protocol/openid-connect/token
ユーザー情報: http://keycloak.homelab.local/realms/homelab/protocol/openid-connect/userinfo
公開鍵:   http://keycloak.homelab.local/realms/homelab/protocol/openid-connect/certs
```

---

## よく使うコマンド

```bash
# Pod の状態確認
kubectl get pods -n keycloak

# Keycloak のログ確認
kubectl logs -n keycloak -l app=keycloak --tail=50

# OIDC エンドポイントの疎通確認
curl http://keycloak.homelab.local/realms/homelab/.well-known/openid-configuration | \
  python3 -m json.tool | head -30

# Keycloak Admin API でユーザー一覧取得 (Token 取得後)
TOKEN=$(curl -s -X POST \
  http://keycloak.homelab.local/realms/master/protocol/openid-connect/token \
  -d 'client_id=admin-cli&username=admin&password=Keycloak12345&grant_type=password' | \
  python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

curl -H "Authorization: Bearer $TOKEN" \
  http://keycloak.homelab.local/admin/realms/homelab/users
```

---

## トラブルシューティング

### Grafana から Keycloak にリダイレクトされない

`grafana.ini` の `auth.generic_oauth.enabled: true` が設定されているか確認する。
Helm upgrade 後に Grafana Pod を再起動:

```bash
kubectl rollout restart deployment -n monitoring kube-prometheus-stack-grafana
```

### `redirect_uri_mismatch` エラー

Keycloak の Client 設定の `Valid Redirect URIs` が一致していない。

```
Keycloak UI → homelab realm → Clients → grafana → Valid redirect URIs
→ http://grafana.homelab.local/* を追加
```

### ログイン後に `access_denied` エラー

ユーザーに必要なロールが割り当てられていない。

```
Keycloak UI → homelab realm → Users → yuto → Role Mappings
→ admin ロールを追加
```

---

## ファイル構成と各ファイルのコード解説

### ファイル構成一覧

| ファイル | 役割 |
|----------|------|
| `namespace.yaml` | Keycloak 用の Kubernetes Namespace を作成 |
| `keycloak.yaml` | PostgreSQL と Keycloak 本体の全リソースを定義 (Secret, StatefulSet, Deployment, Service, Ingress) |
| `setup.sh` | Keycloak 起動後に Realm・クライアント・ユーザーを自動設定する初期セットアップスクリプト |

---

### namespace.yaml

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: keycloak
```

**解説:**

Kubernetes では、リソースを「Namespace (名前空間)」で論理的に分離する。Keycloak 関連の全リソース (Pod, Service, Secret など) は `keycloak` Namespace に配置される。

これにより以下のメリットがある:
- 他のアプリ (monitoring, harbor など) とリソース名が衝突しない
- `kubectl get pods -n keycloak` で Keycloak 関連だけをフィルタリングできる
- RBAC (アクセス制御) を Namespace 単位で設定できる

---

### keycloak.yaml の全リソース解説

`keycloak.yaml` は YAML のマルチドキュメント形式 (`---` で区切る) で、1ファイルに6つのリソースを定義している。`kubectl apply -f keycloak.yaml` で全リソースが一括作成される。

---

#### 1. PostgreSQL Secret (データベース認証情報)

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: keycloak-postgresql
  namespace: keycloak
type: Opaque
stringData:
  POSTGRES_DB: keycloak
  POSTGRES_USER: keycloak
  POSTGRES_PASSWORD: "keycloak-pg-secret"
```

**解説:**

Secret は機密情報 (パスワード、APIキーなど) を安全に管理するための Kubernetes リソース。

| フィールド | 値 | 意味 |
|-----------|-----|------|
| `POSTGRES_DB` | keycloak | PostgreSQL に作成するデータベース名 |
| `POSTGRES_USER` | keycloak | データベースのユーザー名 |
| `POSTGRES_PASSWORD` | keycloak-pg-secret | データベースのパスワード |

**`stringData` と `data` の違い:**
- `stringData`: 平文で記述できる (apply 時に自動で Base64 エンコードされる)
- `data`: 自分で Base64 エンコードした値を記述する

このパスワードは後述の PostgreSQL StatefulSet と Keycloak Deployment の両方から参照される。PostgreSQL 側では `envFrom` で全キーを環境変数として注入し、Keycloak 側では `secretKeyRef` で `POSTGRES_PASSWORD` キーだけを参照する。

---

#### 2. PostgreSQL StatefulSet

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: keycloak-postgresql
  namespace: keycloak
spec:
  serviceName: keycloak-postgresql
  replicas: 1
  selector:
    matchLabels:
      app: keycloak-postgresql
  template:
    metadata:
      labels:
        app: keycloak-postgresql
    spec:
      containers:
        - name: postgresql
          image: postgres:16-alpine
          ports:
            - containerPort: 5432
          env:
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          envFrom:
            - secretRef:
                name: keycloak-postgresql
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              cpu: 200m
              memory: 512Mi
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        storageClassName: longhorn
        resources:
          requests:
            storage: 5Gi
```

**なぜ Deployment ではなく StatefulSet を使うのか:**

データベースのような「状態を持つ」アプリケーションには StatefulSet が適している。理由:

1. **安定したストレージ**: StatefulSet の `volumeClaimTemplates` により、Pod が再起動・再スケジュールされても同じ PVC (永続ボリューム) が再アタッチされる。Deployment だと Pod 削除時に PVC が孤立するリスクがある
2. **安定したネットワーク ID**: Pod 名が `keycloak-postgresql-0` のように固定される (Deployment だとランダムなサフィックスが付く)
3. **順序付きデプロイ**: レプリカが複数ある場合、0, 1, 2... の順に起動する (データベースのプライマリ/レプリカ構成で重要)

**イメージ `postgres:16-alpine` について:**
- PostgreSQL バージョン 16 (2024年時点の最新安定版)
- Alpine Linux ベース (通常の Debian ベースより軽量、約 80MB vs 400MB)
- Keycloak のユーザー/セッション/設定データを永続化するためのバックエンド DB

**`PGDATA` 環境変数:**
PostgreSQL はデータファイルの保存先を `PGDATA` で指定する。`/var/lib/postgresql/data/pgdata` とサブディレクトリを指定しているのは、マウントポイント直下だと `.lost+found` ディレクトリが存在する場合に PostgreSQL が初期化に失敗するため。

**`envFrom` による Secret 参照:**
`envFrom.secretRef` を使うと、Secret の全キーが環境変数として Pod に注入される。つまり `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD` の3つが自動的に環境変数になる。PostgreSQL の公式 Docker イメージはこれらの環境変数を読み取って自動的にデータベースとユーザーを作成する。

**リソース制限:**

| 設定 | 値 | 意味 |
|------|-----|------|
| `requests.cpu` | 100m | 最低保証 CPU (0.1 コア) |
| `requests.memory` | 256Mi | 最低保証メモリ |
| `limits.cpu` | 200m | 最大 CPU (0.2 コア) |
| `limits.memory` | 512Mi | 最大メモリ (超えると OOMKill) |

ホームラボでは低リソースな NUC で動作するため、控えめに設定している。

**Longhorn 5Gi PVC (`volumeClaimTemplates`):**
- `storageClassName: longhorn` — Longhorn 分散ストレージを使用。ノード障害時にデータが失われない
- `accessModes: ["ReadWriteOnce"]` — 1つの Pod からのみ読み書き可能 (DB には十分)
- `storage: 5Gi` — 5GB のボリュームを確保。Keycloak のメタデータ (ユーザー、セッション、クライアント設定) には十分な容量

---

#### 3. PostgreSQL Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: keycloak-postgresql
  namespace: keycloak
spec:
  selector:
    app: keycloak-postgresql
  ports:
    - port: 5432
```

**解説:**

Service は Pod への安定したネットワークエンドポイントを提供する。Pod は再起動のたびに IP が変わるが、Service 名 (`keycloak-postgresql`) は固定される。

Keycloak は `jdbc:postgresql://keycloak-postgresql:5432/keycloak` という JDBC URL でこの Service 経由で PostgreSQL に接続する。Kubernetes の DNS が `keycloak-postgresql` を自動解決する。

`port: 5432` のみ指定して `targetPort` を省略しているため、Service のポート (5432) がそのまま Pod のポート (5432) に転送される。

---

#### 4. Keycloak Admin Secret

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: keycloak-admin
  namespace: keycloak
type: Opaque
stringData:
  KEYCLOAK_ADMIN: admin
  KEYCLOAK_ADMIN_PASSWORD: "Keycloak12345"
```

**解説:**

Keycloak の初回起動時に作成される管理者アカウントの認証情報。

| フィールド | 値 | 意味 |
|-----------|-----|------|
| `KEYCLOAK_ADMIN` | admin | Keycloak 管理コンソールのユーザー名 |
| `KEYCLOAK_ADMIN_PASSWORD` | Keycloak12345 | 管理コンソールのパスワード |

これらの環境変数は Keycloak コンテナに `envFrom` で注入される。Keycloak は初回起動時にこれらの値で master realm の admin ユーザーを自動作成する。2回目以降の起動では既にユーザーが存在するため無視される。

---

#### 5. Keycloak Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keycloak
  namespace: keycloak
spec:
  replicas: 1
  selector:
    matchLabels:
      app: keycloak
  template:
    metadata:
      labels:
        app: keycloak
    spec:
      containers:
        - name: keycloak
          image: quay.io/keycloak/keycloak:26.3.3
          args:
            - start
            - --proxy-headers=xforwarded
            - --hostname-strict=false
            - --http-enabled=true
          ports:
            - containerPort: 8080
          envFrom:
            - secretRef:
                name: keycloak-admin
          env:
            - name: KC_DB
              value: postgres
            - name: KC_DB_URL
              value: jdbc:postgresql://keycloak-postgresql:5432/keycloak
            - name: KC_DB_USERNAME
              value: keycloak
            - name: KC_DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: keycloak-postgresql
                  key: POSTGRES_PASSWORD
          resources:
            requests:
              cpu: 200m
              memory: 512Mi
            limits:
              cpu: 500m
              memory: 1Gi
          readinessProbe:
            httpGet:
              path: /realms/master
              port: 8080
            initialDelaySeconds: 120
            periodSeconds: 10
            failureThreshold: 12
          livenessProbe:
            httpGet:
              path: /realms/master
              port: 8080
            initialDelaySeconds: 300
            periodSeconds: 30
            failureThreshold: 3
```

**なぜ StatefulSet ではなく Deployment なのか:**

Keycloak 自体はステートレス (状態を持たない) なアプリケーション。全てのデータは PostgreSQL に保存されるため、Keycloak の Pod が再起動しても問題ない。Deployment を使うことでローリングアップデートが容易になる。

**イメージ `quay.io/keycloak/keycloak:26.3.3`:**

Keycloak の公式コンテナイメージ。バージョン 26.3.3 を明示的にピン留めしている (`:latest` を使うと予期しないバージョンアップで壊れる恐れがある)。

**起動引数 (`args`) の詳細解説:**

| 引数 | 意味 |
|------|------|
| `start` | Keycloak を本番モードで起動 (開発モードは `start-dev`) |
| `--proxy-headers=xforwarded` | リバースプロキシ (Traefik) からの `X-Forwarded-*` ヘッダーを信頼する。これがないとリダイレクト URL が `http://pod-ip:8080/...` になってしまう |
| `--hostname-strict=false` | ホスト名の厳密チェックを無効化。ホームラボでは DNS 名が内部用のため、外部からの検証を緩和する |
| `--http-enabled=true` | HTTP (非 HTTPS) でのアクセスを許可。ホームラボ内部では TLS 終端を Traefik (Ingress) で行うため、Keycloak 自体は HTTP で動作する |

**環境変数によるデータベース接続:**

| 環境変数 | 値 | 説明 |
|---------|-----|------|
| `KC_DB` | postgres | バックエンド DB の種類 (H2, mysql, postgres, mariadb 等) |
| `KC_DB_URL` | jdbc:postgresql://keycloak-postgresql:5432/keycloak | JDBC 接続 URL。`keycloak-postgresql` は Kubernetes Service 名で DNS 解決される |
| `KC_DB_USERNAME` | keycloak | DB ユーザー名 |
| `KC_DB_PASSWORD` | (Secret から取得) | `secretKeyRef` で PostgreSQL Secret の `POSTGRES_PASSWORD` キーの値を取得 |

**readinessProbe と livenessProbe:**

| Probe | initialDelaySeconds | 意味 |
|-------|--------------------:|------|
| readinessProbe | 120秒 (2分) | 「トラフィックを受け付けていいか」の判定。120秒待つのは、Keycloak の起動 (Java アプリ + DB マイグレーション) に時間がかかるため |
| livenessProbe | 300秒 (5分) | 「Pod がハングしていないか」の判定。300秒待つのは、初回起動時の DB スキーマ作成がさらに遅い場合があるため |

**なぜ初期遅延が長いのか:**
- Keycloak は Java (Quarkus) ベースで、JVM の起動自体に時間がかかる
- 初回起動時は PostgreSQL にテーブルを作成する DB マイグレーションが走る
- ホームラボの NUC は CPU が限られており (i3-5010U)、起動が遅い
- `initialDelaySeconds` が短すぎると、起動途中で「応答なし」と判定されて Pod が何度も再起動される (CrashLoopBackOff)

**`readinessProbe` の `failureThreshold: 12`:**
120秒の初期遅延 + 10秒間隔 x 12回 = 最大 240秒 (4分) 待ってから Not Ready と判定。つまり合計約 6分の猶予がある。

**`livenessProbe` の `failureThreshold: 3`:**
300秒の初期遅延 + 30秒間隔 x 3回 = 最大 390秒後に Pod を再起動。起動に約 6.5分以上かかる場合は Pod が Kill される。

---

#### 6. Keycloak Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: keycloak
  namespace: keycloak
spec:
  selector:
    app: keycloak
  ports:
    - port: 80
      targetPort: 8080
```

**解説:**

| 設定 | 値 | 意味 |
|------|-----|------|
| `port` | 80 | Service が外部に公開するポート |
| `targetPort` | 8080 | 実際に Pod が Listen しているポート |

**なぜ port 80 → targetPort 8080 にしているのか:**

Ingress からのトラフィックは HTTP (ポート80) で Service に到達する。Service はそれを Pod の 8080 ポートに転送する。こうすることで Ingress の設定で `port.number: 80` と自然に書ける。

---

#### 7. Keycloak Ingress

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: keycloak
  namespace: keycloak
spec:
  ingressClassName: traefik
  rules:
    - host: keycloak.homelab.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: keycloak
                port:
                  number: 80
```

**解説:**

Ingress は外部からクラスター内の Service へのアクセスを制御するリソース。

| 設定 | 値 | 意味 |
|------|-----|------|
| `ingressClassName` | traefik | k3s に標準搭載されている Traefik Ingress Controller を使用 |
| `host` | keycloak.homelab.local | このホスト名でアクセスが来た場合にマッチ |
| `path: /` | 全パス | ルート以下全てのリクエストを転送 |
| `pathType: Prefix` | 前方一致 | `/realms/homelab` も `/admin` もすべてマッチ |

**アクセスの流れ:**
```
ブラウザ → http://keycloak.homelab.local
    ↓ (DNS で 192.168.210.25 に解決)
Traefik (NodePort で全ノードの 80 番ポートで Listen)
    ↓ (Host ヘッダーが keycloak.homelab.local → この Ingress にマッチ)
keycloak Service (port 80)
    ↓ (targetPort 8080 に転送)
keycloak Pod (containerPort 8080)
```

---

### setup.sh の処理フロー解説

`setup.sh` は Keycloak が起動した後に実行する初期セットアップスクリプト。Realm の作成、OIDC クライアントの登録、ユーザー作成、各アプリの SSO 設定を自動化する。

**実行場所:** Raspberry Pi (Ansible/Terraform 実行環境)

**前提条件:** Keycloak と Harbor が起動済みであること

---

#### STEP 1: CoreDNS カスタム設定

```bash
kubectl apply -f ../coredns-custom.yaml
kubectl rollout restart deployment/coredns -n kube-system
kubectl rollout status deployment/coredns -n kube-system --timeout=60s
```

**なぜ CoreDNS の設定が必要なのか:**

Keycloak の setup.sh は Pod 内から `kcadm.sh` を実行する。その際に他のサービス (Harbor など) と通信する必要がある。しかし `keycloak.homelab.local` などのホスト名はクラスター内の CoreDNS ではデフォルトで解決できない (外部 DNS のみ)。

`coredns-custom.yaml` は `*.homelab.local` をクラスター内の Service IP に解決するカスタムルールを追加する。これにより Pod 内から `http://keycloak.homelab.local/...` のような URL でアクセスできるようになる。

---

#### Keycloak Pod 起動待ち

```bash
kubectl wait --for=condition=ready pod -l app=keycloak -n keycloak --timeout=300s
```

readinessProbe が成功するまで最大5分待つ。Keycloak が完全に起動してリクエストを受け付けられる状態になるのを確認してから次の設定に進む。

---

#### STEP 2: kcadm ログイン

```bash
kubectl exec -n keycloak "${POD}" -- \
  /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 --realm master \
  --user admin --password "Keycloak12345"
```

**`kcadm.sh` とは:**

Keycloak Admin CLI — Keycloak の管理操作をコマンドラインから実行するためのツール。Keycloak コンテナ内に `/opt/keycloak/bin/kcadm.sh` として同梱されている。

`config credentials` コマンドで管理者トークンを取得し、以降のコマンドで自動的にそのトークンが使われる。`--server http://localhost:8080` は Pod 内から自分自身にアクセスするため localhost を使う。

---

#### STEP 3: homelab Realm 作成

```bash
kubectl exec -n keycloak "${POD}" -- \
  /opt/keycloak/bin/kcadm.sh create realms \
  -s realm=homelab -s enabled=true -s displayName="Homelab"
```

`homelab` という名前の Realm を作成する。このラボの全アプリ (Grafana, ArgoCD, Harbor 等) はこの Realm に属するクライアントとして登録される。

**`-s` オプション:** 属性を key=value 形式で設定する。

---

#### STEP 3b: groups Client Scope 作成

```bash
GROUPS_SCOPE_ID=$(kubectl exec -n keycloak "${POD}" -- \
  /opt/keycloak/bin/kcadm.sh create client-scopes -r homelab \
  -s name=groups -s protocol=openid-connect \
  -s 'attributes={"include.in.token.scope":"true","display.on.consent.screen":"false"}' \
  -i)
```

**Client Scope とは:**

OIDC トークンに含める情報のセットを定義するもの。`groups` スコープを作成することで、トークンにユーザーのグループ情報を含められるようになる。

- `include.in.token.scope: true` — トークンのスコープに含める
- `display.on.consent.screen: false` — ユーザーに同意画面を表示しない (ホームラボなので不要)
- `-i` フラグ — 作成されたリソースの ID を標準出力に返す (後で変数として使用)

---

#### STEP 4: 6つの OIDC クライアント作成

各アプリを Keycloak のクライアントとして登録する:

| クライアントID | redirectUri | 用途 |
|---------------|-------------|------|
| `argocd` | `http://argocd.homelab.local/auth/callback` | ArgoCD の OIDC コールバック |
| `grafana` | `http://grafana.homelab.local/login/generic_oauth` | Grafana の Generic OAuth コールバック |
| `harbor` | `http://harbor.homelab.local/c/oidc/callback` | Harbor の OIDC コールバック |
| `vault` | `http://vault.homelab.local/ui/vault/auth/oidc/oidc/callback` と `/oidc/callback` | Vault は UI と CLI で2つのコールバック URL を持つ |
| `minio` | `http://minio.homelab.local/oauth_callback` | MinIO Console の OAuth コールバック |
| `kibana` | `http://kibana.homelab.local/oauth2/callback` | oauth2-proxy 経由の Kibana コールバック |

**共通設定:**
- `publicClient=false` — Confidential クライアント (Client Secret を使う)
- `secret=xxx-keycloak-secret-2026` — 各アプリの values.yaml に設定するシークレット
- `standardFlowEnabled=true` — Authorization Code Flow (最もセキュアな OIDC フロー) を有効化
- `webOrigins` — CORS (クロスオリジンリクエスト) を許可するオリジン

**redirectUri が各アプリで異なる理由:**

OIDC のログインフローでは、Keycloak がユーザー認証後に「Authorization Code」をアプリに渡すためにリダイレクトする。このリダイレクト先 URL はアプリごとに異なるパスが決められている:
- Grafana は `/login/generic_oauth`
- ArgoCD は `/auth/callback`
- Harbor は `/c/oidc/callback`

Keycloak は登録された `redirectUri` 以外へのリダイレクトを拒否する (オープンリダイレクト攻撃の防止)。

---

#### STEP 5: グループ・管理ユーザー作成

```bash
# homelab-admins グループ作成
kubectl exec ... -- kcadm.sh create groups -r homelab -s name=homelab-admins

# admin ユーザー作成
kubectl exec ... -- kcadm.sh create users -r homelab \
  -s username=admin -s enabled=true -s email=admin@homelab.local -s emailVerified=true

# パスワード設定
kubectl exec ... -- kcadm.sh set-password -r homelab \
  --username admin --new-password "Keycloak12345"
```

- `homelab-admins` グループ: このグループに所属するユーザーは各アプリで管理者権限を持つ
- `admin` ユーザー: homelab realm 用の管理ユーザー (master realm の admin とは別)
- `emailVerified=true`: メール検証済みフラグを立てておくことで、ログイン時に「メールを確認してください」画面が出ない

---

#### STEP 6: groups mapper 追加 (全クライアント)

```bash
for CLIENT in argocd grafana harbor vault minio kibana; do
  # クライアントの UUID を取得
  CLIENT_UUID=$(... kcadm.sh get clients -r homelab -q clientId=${CLIENT} --fields id ...)

  # groups mapper: トークンにグループ情報を含める
  kcadm.sh create clients/${CLIENT_UUID}/protocol-mappers/models -r homelab \
    -s protocolMapper=oidc-group-membership-mapper \
    -s 'config={"full.path":"false","id.token.claim":"true","access.token.claim":"true","claim.name":"groups","userinfo.token.claim":"true"}'

  # audience mapper: aud クレームに clientId を含める
  kcadm.sh create clients/${CLIENT_UUID}/protocol-mappers/models -r homelab \
    -s protocolMapper=oidc-audience-mapper \
    -s 'config={"included.client.audience":"${CLIENT}","id.token.claim":"true","access.token.claim":"true"}'

  # groups client scope をデフォルトスコープに割り当て
  kcadm.sh update clients/${CLIENT_UUID}/default-client-scopes/${GROUPS_SCOPE_ID} -r homelab
done
```

**Protocol Mapper とは:**

OIDC トークン (JWT) に含めるデータを制御する仕組み。デフォルトではグループ情報はトークンに含まれないため、明示的に mapper を追加する必要がある。

**groups mapper (`oidc-group-membership-mapper`):**
- トークンの `groups` クレームにユーザーの所属グループ一覧を含める
- `full.path: false` — グループの完全パス (`/parent/child`) ではなく名前だけ (`child`) を含める
- 各アプリはこの `groups` クレームを読み取って権限判定を行う (例: `homelab-admins` に所属 → Admin)

**audience mapper (`oidc-audience-mapper`):**
- JWT の `aud` (audience) クレームにクライアント ID を含める
- 一部のアプリ (特に Vault) はトークンの `aud` に自分のクライアント ID が含まれていることを検証する

**default-client-scopes への割り当て:**
- `groups` スコープを各クライアントのデフォルトスコープに追加
- これにより、クライアントがトークンリクエスト時に `scope=groups` を明示しなくても自動的にグループ情報が含まれる

---

#### STEP 7: MinIO policy mapper 追加

```bash
kcadm.sh create clients/${MINIO_UUID}/protocol-mappers/models -r homelab \
  -s protocolMapper=oidc-hardcoded-claim-mapper \
  -s 'config={"claim.name":"policy","claim.value":"consoleAdmin","jsonType.label":"String",...}'
```

**MinIO 固有の設定:**

MinIO は OIDC トークン内の `policy` クレームを読み取って、MinIO のアクセスポリシーにマッピングする。`oidc-hardcoded-claim-mapper` は全ユーザーに固定値 `consoleAdmin` を返す。

これは「Keycloak でログインできるユーザーは全員 MinIO の管理者」という設定。ホームラボでは管理者のみがアクセスするため、このシンプルな設定で十分。

---

#### STEP 8: Harbor OIDC 設定

```bash
kubectl exec -n harbor "${HARBOR_POD}" -- curl -s -X PUT \
  -u "admin:${HARBOR_PASS}" http://localhost:8080/api/v2.0/configurations \
  -H 'Content-Type: application/json' \
  -d '{
    "auth_mode":"oidc_auth",
    "oidc_name":"Keycloak",
    "oidc_endpoint":"http://keycloak.homelab.local/realms/homelab",
    "oidc_client_id":"harbor",
    "oidc_client_secret":"harbor-keycloak-secret-2026",
    "oidc_scope":"openid,profile,email,groups",
    "oidc_verify_cert":false,
    "oidc_auto_onboard":true,
    "oidc_user_claim":"sub",
    "oidc_groups_claim":"groups",
    "oidc_admin_group":"homelab-admins"
  }'
```

**Harbor API による OIDC 設定:**

Harbor は Web UI からも OIDC を設定できるが、自動化のために REST API を使用する。Harbor Core Pod 内から `localhost:8080` の管理 API を叩いている。

| パラメータ | 値 | 意味 |
|-----------|-----|------|
| `auth_mode` | oidc_auth | 認証方式を OIDC に切り替え (既存の DB 認証も併用可能) |
| `oidc_endpoint` | `http://keycloak.homelab.local/realms/homelab` | OIDC プロバイダーの URL |
| `oidc_verify_cert` | false | TLS 証明書の検証を無効化 (ホームラボでは自己証明書のため) |
| `oidc_auto_onboard` | true | 初回 OIDC ログイン時に Harbor ユーザーを自動作成 |
| `oidc_admin_group` | homelab-admins | このグループのユーザーを Harbor 管理者にする |

---

#### STEP 9: Vault OIDC 設定

```bash
# Vault の状態確認 (sealed かどうか)
VAULT_SEALED=$(... vault status -format=json ... | ... "sealed":true/false ...)

# unsealed の場合のみ設定
VAULT_TOKEN=$(... vault login -method=userpass ... username=admin password=Vault12345 ...)

# OIDC 認証バックエンドを有効化
vault auth enable oidc

# OIDC プロバイダー設定
vault write auth/oidc/config \
  oidc_discovery_url="http://keycloak.homelab.local/realms/homelab" \
  oidc_client_id="vault" \
  oidc_client_secret="vault-keycloak-secret-2026" \
  default_role="keycloak"

# OIDC ロール設定
vault write auth/oidc/role/keycloak \
  bound_audiences="vault" \
  allowed_redirect_uris="http://vault.homelab.local/ui/vault/auth/oidc/oidc/callback" \
  allowed_redirect_uris="http://vault.homelab.local/oidc/callback" \
  user_claim="preferred_username" \
  groups_claim="groups" \
  policies="admin-policy" \
  oidc_scopes="openid,profile,email,groups"
```

**Vault OIDC 設定の特殊性:**

1. **Sealed チェック**: Vault は初期化後に「sealed (封印)」状態になる。unsealed でないと設定変更ができないため、事前に状態を確認する
2. **userpass ログイン**: Vault の root トークンではなく、事前に作成された userpass 認証の admin ユーザーでログインする
3. **2つの redirect_uri**: Vault は UI (`/ui/vault/auth/oidc/oidc/callback`) と CLI (`/oidc/callback`) で異なるコールバック URL を使用する
4. **エラーハンドリング**: Vault が sealed の場合やログイン失敗時はスキップし、後から手動で再実行できるようにしている

**`bound_audiences`:** トークンの `aud` クレームに `vault` が含まれていることを検証する (STEP 6 で追加した audience mapper が必要な理由)

**`policies="admin-policy"`:** OIDC でログインしたユーザーに `admin-policy` を付与する。このポリシーは別途 Vault に定義済みで、全シークレットへの読み書き権限を持つ。
