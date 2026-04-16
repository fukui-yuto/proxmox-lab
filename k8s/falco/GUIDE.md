# Falco ガイド

## 概要

Falco は syscall レベルでコンテナ・ホストの挙動を監視するランタイム脅威検知ツール。
Kyverno が Admission 時 (デプロイ前) のポリシー違反を検知するのに対し、Falco は **実行時** の異常を検知する補完的な役割を持つ。

### Kyverno との比較

| 機能 | Kyverno | Falco |
|------|---------|-------|
| タイミング | Admission (デプロイ時) | Runtime (実行時) |
| 検知対象 | マニフェスト違反 | syscall 異常 / 不審な動作 |
| 対応 | ブロック / Mutate | アラート送信 |
| eBPF | 不要 | modern_ebpf ドライバー使用 |

---

## ドライバー

| ドライバー | 説明 | 推奨環境 |
|-----------|------|---------|
| `kmod` | カーネルモジュール | 古い環境 |
| `ebpf` | eBPF プログラム | カーネル 4.14+ |
| `modern_ebpf` | CO-RE eBPF (カーネルヘッダー不要) | カーネル 5.8+ (推奨) |

homelab の k3s ノードは Ubuntu 22.04 (カーネル 5.15+) のため `modern_ebpf` を使用。

---

## デフォルトルール (例)

Falco にはデフォルトルールセットが付属している。

| ルール | 説明 |
|--------|------|
| Terminal shell in container | コンテナ内でシェルが起動 |
| Write below binary dir | /bin, /sbin への書き込み |
| Read sensitive file untrusted | /etc/shadow 等への不審なアクセス |
| Outbound connection to C2 servers | 既知の C2 サーバーへの接続 |
| Privilege escalation via su or sudo | 特権昇格の試み |

---

## Falcosidekick によるアラート転送

Falcosidekick は Falco からアラートを受け取り、各種出力先に転送するサイドカー。

```
Falco → Falcosidekick → Alertmanager → aiops-alerting → 通知
```

homelab では Alertmanager に転送することで Grafana アラートと統合する。

---

## カスタムルールの追加

```yaml
# values.yaml に追記
customRules:
  my-rules.yaml: |-
    - rule: Unexpected outbound connection
      desc: Detect unexpected outbound connections
      condition: >
        outbound and not proc.name in (allowed_processes)
      output: >
        Unexpected outbound connection (proc=%proc.name
        src=%fd.sip:%fd.sport dst=%fd.dip:%fd.dport)
      priority: WARNING
```

---

## 確認コマンド

```bash
# Falco Pod のログ (リアルタイム検知)
kubectl logs -n falco -l app.kubernetes.io/name=falco -f

# Falcosidekick UI
# http://falco.homelab.local

# アラート統計
kubectl logs -n falco -l app=falcosidekick | grep -i alert
```
