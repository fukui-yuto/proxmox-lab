# 用語集 (Glossary)

このホームラボプロジェクトで使われる用語の解説です。初心者向けに簡潔にまとめています。

---

## Proxmox / 仮想化

| 用語 | 説明 |
|------|------|
| Corosync | クラスター内のノード間で通信・死活監視を行うプロトコル。ノードの参加・離脱を検知する |
| HA (High Availability) | 高可用性。あるノードが故障しても、別のノードで VM を自動的に再起動する仕組み |
| KVM | Linux カーネルに組み込まれた仮想化機能。ハードウェア支援により高速に VM を実行できる |
| LXC | Linux コンテナ。VM より軽量で、ホスト OS のカーネルを共有して動作する仮想化方式 |
| PBS (Proxmox Backup Server) | Proxmox 専用のバックアップサーバー。増分バックアップと重複排除に対応 |
| Proxmox Replication | ZFS スナップショットの差分をノード間で定期同期し、HA フェイルオーバーを高速化する機能 |
| PXE | ネットワーク経由で OS をブートする技術。Proxmox の自動インストールなどに使う |
| QDevice (Quorum Device) | 2 ノードクラスターで多数決が成立しない問題を解決する外部投票デバイス。スプリットブレイン (両ノードが同時に「自分が正」と主張) を防止する |
| STONITH (Shoot The Other Node In The Head) | フェンシングとも呼ばれる。障害が疑われるノードを強制的に電源オフにして、データ破損を防ぐ仕組み |
| VLAN | 物理的な LAN ケーブル 1 本で、論理的に複数のネットワークを分離する技術。管理用とストレージ用を分けるなどに使う |
| ZFS | コピーオンライト方式のファイルシステム。スナップショット・レプリケーション・データ整合性チェックに対応 |

---

## Kubernetes 基本

| 用語 | 説明 |
|------|------|
| CRD (Custom Resource Definition) | Kubernetes を拡張して独自のリソース種別を追加する仕組み。Prometheus の ServiceMonitor なども CRD |
| DaemonSet | クラスター内の全ノード (または条件に合うノード) に 1 つずつ Pod を配置するリソース。ログ収集エージェントなどに使う |
| Deployment | ステートレス (状態を持たない) アプリ向け。ローリングアップデートやスケールアウトを管理する |
| Helm | Kubernetes のパッケージマネージャー。複雑なマニフェスト群をテンプレート化して簡単にデプロイできる |
| HelmRelease / HelmChartConfig | Helm チャートを Git で宣言的に管理するためのリソース。values の上書きなどを YAML で定義する |
| Ingress | HTTP/HTTPS トラフィックをドメイン名やパスに基づいて適切な Service にルーティングする仕組み |
| Namespace | クラスター内のリソースを論理的に分離する単位。チームやアプリごとに分けて管理する |
| Pod | Kubernetes の最小デプロイ単位。1 つ以上のコンテナをまとめたもの |
| PVC (PersistentVolumeClaim) | Pod が永続ストレージを要求するためのリソース。Pod が削除されてもデータが残る |
| RBAC | ロールベースアクセス制御。「誰が」「何を」できるかをロール単位で定義する |
| Service (ClusterIP / NodePort / LoadBalancer) | Pod へのネットワークアクセスを抽象化する。ClusterIP はクラスター内部のみ、NodePort はノードのポートで公開、LoadBalancer は外部 LB を利用 |
| StatefulSet | データベースなど永続データを持つアプリ向け。Pod に固定の名前と順序付きデプロイを保証する |
| Taint / Toleration | ノードに「汚れ (Taint)」を付けて Pod のスケジュールを制限し、特定の Pod だけが「許容 (Toleration)」して配置される仕組み |

---

## GitOps / CI/CD

| 用語 | 説明 |
|------|------|
| App of Apps パターン | ArgoCD で親アプリケーションが複数の子アプリケーションを管理する構成。全体を一元管理できる |
| ArgoCD | GitOps コントローラー。Git リポジトリの状態と Kubernetes クラスターの状態を自動で同期する |
| Argo Events | Webhook や Kafka などのイベントをトリガーにワークフローや Kubernetes リソースを起動する仕組み |
| Argo Rollouts | カナリアリリースや Blue-Green デプロイなど、段階的にトラフィックを切り替えるプログレッシブデリバリーツール |
| Argo Workflows | DAG (有向非巡回グラフ) ベースのワークフローエンジン。複数ステップの処理を定義・実行する |
| GitOps | Git リポジトリを「唯一の正しい状態 (Single Source of Truth)」として、宣言的にインフラやアプリをデプロイする手法 |
| ServerSideApply | Kubernetes サーバー側でリソースを適用する方式。フィールドの所有権を管理し、複数コントローラーの競合を防ぐ |
| Sync Wave | ArgoCD のデプロイ順序制御。数値が小さいリソースから順に適用される (例: Wave 0 → Wave 1 → ...) |

---

## ネットワーク / CNI

| 用語 | 説明 |
|------|------|
| Cilium | eBPF を活用した高性能な CNI プラグイン。ネットワークポリシーや可観測性も提供する |
| eBPF | Linux カーネル内でプログラムを安全に実行する技術。パケット処理やセキュリティ監視を高速に行える |
| flannel | シンプルで軽量な CNI プラグイン。このラボでは Cilium に移行済み |
| Hubble | Cilium に付属するネットワーク可観測性ツール。通信フローをリアルタイムに可視化する |
| kubeProxyReplacement (KPR) | kube-proxy の機能を Cilium の eBPF で置き換えるモード。環境によっては互換性問題が発生する |
| Traefik | Ingress コントローラー兼リバースプロキシ。HTTP ルーティングや TLS 終端を担当する |
| VXLAN | オーバーレイネットワークのトンネリング技術。物理ネットワーク上に仮想的な L2 ネットワークを構築する |

---

## オブザーバビリティ

| 用語 | 説明 |
|------|------|
| Alertmanager | Prometheus からのアラートを受け取り、重複排除・グループ化して Slack や Email に通知する |
| Elasticsearch | ログを保存し全文検索できるエンジン。大量のログから素早く情報を見つけ出せる |
| Fluent Bit | 軽量なログ収集エージェント。各ノードでログを収集し Elasticsearch などに転送する |
| Grafana | メトリクスやログを美しいダッシュボードで可視化するツール |
| Grafana Tempo | 分散トレースデータを保存・検索するバックエンド。リクエストのサービス間遷移を追跡できる |
| Kibana | Elasticsearch に保存されたログを検索・可視化する Web UI |
| OpenTelemetry (OTel) | メトリクス・ログ・トレースを統一的に収集するための標準仕様・ライブラリ群 |
| Prometheus | メトリクス (数値データ) を定期的にスクレイプして時系列データベースに保存する監視システム |
| ServiceMonitor | Prometheus が監視対象を自動検出するための CRD。ラベルで対象 Service を指定する |

---

## セキュリティ

| 用語 | 説明 |
|------|------|
| cert-manager | Kubernetes 上で TLS 証明書の発行・更新を自動化するコントローラー |
| ClusterIssuer | cert-manager の証明書発行者をクラスター全体スコープで定義するリソース |
| Falco | syscall (システムコール) を監視し、コンテナ内の不審な動作をリアルタイムに検知するセキュリティツール |
| Keycloak | SSO (シングルサインオン) と OIDC 認証を提供する ID 管理基盤 |
| Kyverno | Kubernetes のポリシーエンジン。リソース作成時にルールを適用し、違反を拒否または修正する |
| oauth2-proxy | OIDC/OAuth2 認証をリバースプロキシで代行するミドルウェア。アプリ側に認証実装が不要になる |
| OIDC (OpenID Connect) | OAuth2 の上に認証レイヤーを追加したプロトコル。「この人は誰か」を安全に確認できる |
| Trivy | コンテナイメージや設定ファイルの脆弱性をスキャンするツール |
| Vault | HashiCorp 製のシークレット管理ツール。パスワードや API キーを安全に保管・配布する |

---

## ストレージ / バックアップ

| 用語 | 説明 |
|------|------|
| CSI (Container Storage Interface) | Kubernetes とストレージシステムを接続する標準インターフェース |
| Longhorn | Kubernetes ネイティブの分散ブロックストレージ。レプリカを複数ノードに分散して保存する |
| MinIO | S3 互換の軽量オブジェクトストレージ。バックアップデータの保存先などに使う |
| Velero | Kubernetes リソースと PVC のバックアップ・リストアを行うツール。災害復旧 (DR) に対応 |

---

## その他

| 用語 | 説明 |
|------|------|
| Ansible | エージェントレスの構成管理ツール。SSH 経由でサーバーの設定を自動化する |
| Backstage | Spotify 発の開発者ポータル。サービスカタログやドキュメントを一元管理する |
| Cloud-init | VM の初回起動時にホスト名・ネットワーク・SSH 鍵などを自動設定する仕組み |
| Crossplane | Kubernetes の CRD を使ってクラウドインフラを宣言的に管理するツール |
| IaC (Infrastructure as Code) | インフラの構成をコードとして管理する手法。再現性と変更履歴の追跡が可能になる |
| KEDA | Prometheus や Kafka などのイベントソースに基づいて Pod を自動スケールするツール |
| Litmus | カオスエンジニアリングツール。意図的に障害を注入してシステムの耐障害性を検証する |
| Packer | HashiCorp 製の VM テンプレートビルドツール。OS インストール済みのイメージを自動作成する |
| Terraform | HashiCorp 製の宣言的インフラプロビジョニングツール。HCL でインフラの「あるべき状態」を定義する |
