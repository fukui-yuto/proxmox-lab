# トラブルシューティングガイド

このドキュメントでは、Proxmox ホームラボで発生する既知の問題とその復旧手順をまとめる。

---

## 一般的なトラブルシューティング手順

問題が発生した場合、以下の手順で状況を把握する。

### ログ確認方法

```bash
# Pod のログを確認
kubectl logs <pod-name> -n <namespace>
kubectl logs <pod-name> -n <namespace> --previous  # クラッシュした前のコンテナのログ

# Proxmox ホストのシステムログ
journalctl -u pve-cluster --since "10 minutes ago"
journalctl -u corosync --since "10 minutes ago"

# Kibana での確認
# http://kibana.homelab.local でログ検索 (fluent-bit 経由で収集済み)
```

### Pod 状態確認

```bash
# 正常でない Pod を一覧表示
kubectl get pods --all-namespaces | grep -v Running | grep -v Completed

# 特定の Pod の詳細 (イベント含む)
kubectl describe pod <pod-name> -n <namespace>

# Pod のリソース使用量
kubectl top pods -n <namespace>
```

### ノード状態確認

```bash
# ノード一覧と状態
kubectl get nodes -o wide

# 特定ノードの詳細 (conditions, allocatable リソース)
kubectl describe node <node-name>

# ノードのリソース使用量
kubectl top nodes
```

### ArgoCD UI での確認方法

1. http://argocd.homelab.local にアクセス (`admin` / `Argocd12345`)
2. アプリ一覧で Sync Status と Health Status を確認
3. 問題のあるアプリをクリック → リソースツリーでエラー箇所を特定
4. 「DIFF」タブで期待される状態との差分を確認
5. 「EVENTS」タブでイベント履歴を確認

---

## 既知の問題と対処

### 1. pve-node01 e1000e NIC Hardware Unit Hang

**症状:**
- k8s の全アプリを一斉起動すると pve-node01 の NIC がハングする
- Corosync クォーラム喪失 → クラスター全体がクラッシュ
- `dmesg` に `e1000e: Hardware Unit Hang` が出力される

**原因:**
Intel I218-V の e1000e ドライバが大量パケットバーストで Hardware Unit Hang を起こす。k8s の全サービスが同時に起動すると、NIC が処理しきれない量のパケットが発生する。

**予防策:**

1. NIC チューニング playbook を適用する (k8s 起動前に必ず実行):
   ```bash
   ansible-playbook -i inventory/hosts.yml playbooks/08-nic-tuning.yml
   ```

2. ArgoCD Sync Wave で段階的に起動する (root app で自動制御)

**適用されるチューニング内容:**

| 設定 | 値 | 効果 |
|------|-----|------|
| TSO/GSO/GRO 無効化 | off | NIC ファームウェア負荷軽減 |
| RX/TX リングバッファ | 4096 | バースト時のパケットドロップ防止 |
| 割り込みコアレシング | rx-usecs/tx-usecs=50 | 割り込みストーム抑制 |
| txqueuelen | 10000 | 送信キュー詰まり防止 |

**復旧手順:**

NIC がハングした場合、ソフトウェアからの復旧は不可能。以下の手順で対応する:

1. pve-node01 の電源ボタンを長押しして強制シャットダウン
2. 10 秒以上待ってから電源を入れ直す
3. 起動後、`pvecm status` でクォーラムが回復していることを確認
4. NIC チューニング playbook を再適用:
   ```bash
   ansible-playbook -i inventory/hosts.yml playbooks/08-nic-tuning.yml
   ```
5. k8s のアプリが Sync Wave に従って段階的に起動することを確認

---

### 2. Cilium kubeProxyReplacement と ClusterIP 全断

**症状:**
- `kubeProxyReplacement: true` に設定すると DNS を含む全 ClusterIP が到達不能になる
- ArgoCD を含む全サービス間通信が全断する
- Pod 内から `nslookup kubernetes.default` が失敗する

**原因:**
KPR=true + tunnel (VXLAN) モードでは socketLB (cgroup BPF) が ClusterIP DNAT を処理する必要があるが、k3s の containerd 環境では Cilium コンテナの cgroup namespace がホストと分離されており BPF プログラムが Pod の cgroup にアタッチできない。

**対処:**
- `k8s/cilium/values.yaml` で `kubeProxyReplacement: false` を維持する
- **絶対に true にしない**
- `bpf.masquerade: false` も維持する (KPR=false では NodePort BPF が無効のため)

**もし true にしてしまった場合の復旧手順:**

1. `k8s/cilium/values.yaml` を編集して `kubeProxyReplacement: false` に戻す
2. git commit && git push
3. ArgoCD が Sync 不能の場合 (通信全断のため)、Raspberry Pi から手動で helm upgrade:
   ```bash
   # Raspberry Pi 上で実行
   helm upgrade cilium cilium/cilium -n kube-system \
     -f /path/to/values.yaml \
     --set kubeProxyReplacement=false \
     --set bpf.masquerade=false
   ```
4. Cilium Pod が再起動し、通信が復旧するのを待つ
5. `kubectl get pods --all-namespaces` で全 Pod の状態を確認

---

### 3. Cilium ローリングリスタート後の Longhorn ボリューム障害

**症状:**
- Cilium DaemonSet の再起動後に Longhorn ボリュームが faulted/detaching でスタックする
- Pod が I/O エラーでクラッシュする
- `kubectl get volumes.longhorn.io -n longhorn-system` で Faulted 状態のボリュームが見える

**原因:**
Cilium 再起動で Pod ネットワークが更新されるが、既存の Longhorn instance-manager Pod が古いネットワーク情報のまま残る。その結果、instance-manager 間の gRPC 通信が不能になる。

**復旧手順:**

1. Cilium のローリングリスタートが完全に完了するのを待つ:
   ```bash
   kubectl rollout status daemonset/cilium -n kube-system
   ```

2. Longhorn の instance-manager Pod を全て削除 (自動再作成される):
   ```bash
   kubectl delete pods -n longhorn-system -l longhorn.io/component=instance-manager
   ```

3. ボリュームの状態が回復するのを確認:
   ```bash
   kubectl get volumes.longhorn.io -n longhorn-system
   ```

4. まだ Faulted のボリュームがある場合は、該当ボリュームを使用している Pod を再起動:
   ```bash
   kubectl delete pod <pod-name> -n <namespace>
   ```

---

### 4. ArgoCD Sync が stuck / Unknown 状態

**症状:**
- アプリが Sync 中のまま進まない
- Health Status が Unknown 表示
- UI 上でリソースがグレーアウトしている

**確認手順:**

```bash
# アプリの状態を詳細確認
kubectl get app -n argocd <app-name> -o yaml

# ArgoCD application-controller のログ確認
kubectl logs -n argocd -l app.kubernetes.io/component=application-controller --tail=100

# repo-server のログ確認 (マニフェスト生成の問題の場合)
kubectl logs -n argocd -l app.kubernetes.io/component=repo-server --tail=100
```

**対処:**

1. ハードリフレッシュを試す:
   ```bash
   argocd app refresh <app-name> --hard
   ```

2. それでも解消しない場合、application-controller を再起動:
   ```bash
   kubectl rollout restart deployment argocd-application-controller -n argocd
   ```

3. CRD の sync で stuck している場合は、ArgoCD UI から該当リソースを手動で Sync (Replace オプション付き)

---

### 5. Corosync クォーラム喪失

**症状:**
- Proxmox Web UI で "No quorum" と表示される
- VM の起動・停止などの操作ができない
- `pvecm status` で `Quorate: No` と表示される

**原因:**
- 2 ノード以上が通信不能になっている
- QDevice ホスト (Raspberry Pi: 192.168.210.55) が落ちている
- ネットワーク障害

**確認手順:**

```bash
# 各 Proxmox ノードで実行
pvecm status          # クォーラム状態
pvecm nodes           # ノード一覧と接続状態
corosync-cfgtool -s   # リング状態

# QDevice の確認 (Raspberry Pi)
systemctl status corosync-qnetd
```

**復旧手順:**

1. ネットワーク疎通を確認:
   ```bash
   ping 192.168.210.11  # pve-node01
   ping 192.168.210.12  # pve-node02
   ping 192.168.210.13  # pve-node03
   ping 192.168.210.55  # Raspberry Pi (QDevice)
   ```

2. QDevice ホスト (Raspberry Pi) が落ちている場合:
   ```bash
   # Raspberry Pi を再起動後
   sudo systemctl restart corosync-qnetd
   ```

3. 各 Proxmox ノードで corosync を再起動:
   ```bash
   systemctl restart corosync
   ```

4. クォーラムが回復したことを確認:
   ```bash
   pvecm status  # Quorate: Yes を確認
   ```

---

### 6. Pod が Pending のまま (リソース不足)

**症状:**
- Pod が Pending 状態から進まない
- `kubectl describe pod` の Events に `FailedScheduling` が表示される

**確認手順:**

```bash
# Pod のイベントを確認
kubectl describe pod <pod-name> -n <namespace> | grep -A5 Events

# ノードの空きリソースを確認
kubectl top nodes
kubectl describe nodes | grep -A5 "Allocated resources"
```

**対処:**

1. 不要な Pod を削除してリソースを確保:
   ```bash
   # 不要な namespace のアプリを一時停止 (ArgoCD で Sync を無効化)
   argocd app patch <app-name> --patch '{"spec":{"syncPolicy":null}}' --type merge
   kubectl scale deployment <deployment> -n <namespace> --replicas=0
   ```

2. Pod の resource requests が過大でないか確認し、適切な値に調整

3. ワーカーノードのスケールアウトが必要な場合は Terraform で VM を追加

---

### 7. Longhorn ボリュームが Degraded

**症状:**
- Longhorn UI (http://longhorn.homelab.local) でボリュームが Degraded 表示
- レプリカ数が設定値に満たない

**原因:**
- ノード障害でレプリカが失われた
- ディスク容量不足で新しいレプリカを作成できない
- ノード間のネットワーク障害

**確認手順:**

```bash
# ボリューム一覧と状態
kubectl get volumes.longhorn.io -n longhorn-system

# 特定ボリュームの詳細
kubectl describe volume.longhorn.io <volume-name> -n longhorn-system

# ノードのディスク状態
kubectl get nodes.longhorn.io -n longhorn-system -o yaml
```

**対処:**

1. ノード障害の場合: ノード復旧後に Longhorn が自動的にレプリカを再構築する (数分〜数十分かかる)

2. ディスク容量不足の場合:
   - 不要なスナップショットを削除 (Longhorn UI → Volume → Snapshots)
   - Terraform でディスクサイズを拡張

3. 自動回復しない場合は Longhorn UI から手動で操作:
   - Volume → 該当ボリューム → Replica タブ → 「Rebuild Replica」

---

### 8. Vault が Sealed 状態

**症状:**
- Vault にアクセスできない (503 エラー)
- Vault を使用するアプリがシークレットを取得できない
- `vault status` で `Sealed: true` と表示される

**確認手順:**

```bash
# Vault の状態確認
kubectl exec -n vault vault-0 -- vault status

# Vault Pod のログ
kubectl logs -n vault vault-0
```

**対処:**

1. Unseal key を使って手動で unseal:
   ```bash
   # Unseal key は安全な場所に保管されている前提
   kubectl exec -n vault vault-0 -- vault operator unseal <unseal-key-1>
   kubectl exec -n vault vault-0 -- vault operator unseal <unseal-key-2>
   kubectl exec -n vault vault-0 -- vault operator unseal <unseal-key-3>
   ```

2. auto-unseal 設定の場合は、unseal 用のキーソースへの接続を確認

3. Vault Pod がクラッシュループしている場合:
   ```bash
   kubectl delete pod vault-0 -n vault
   # Pod 再作成後に unseal を再実行
   ```

---

## トラブルシューティングのヒント

### よく使うコマンド集

```bash
# 全 namespace のイベントを時系列で確認
kubectl get events --all-namespaces --sort-by='.lastTimestamp'

# 特定 namespace の最新イベント
kubectl get events -n <namespace> --sort-by='.lastTimestamp' | tail -20

# Pod のリスタート回数が多いものを確認
kubectl get pods --all-namespaces --sort-by='.status.containerStatuses[0].restartCount' | tail -10

# ノードの taint を確認
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints

# PVC の状態確認
kubectl get pvc --all-namespaces
```

### 問題切り分けのフローチャート

1. **Pod が起動しない** → `kubectl describe pod` → Events を確認
   - `FailedScheduling` → リソース不足 (問題 6 参照)
   - `ImagePullBackOff` → Harbor / イメージ名を確認
   - `CrashLoopBackOff` → `kubectl logs --previous` でクラッシュ原因を確認

2. **サービスに接続できない** → Pod は Running か確認
   - Running → Service / Ingress の設定確認
   - Not Running → Pod のログ・Events を確認
   - 全サービス不通 → Cilium / kube-proxy の状態確認 (問題 2 参照)

3. **データが消えた / 読めない** → Longhorn ボリュームの状態確認
   - Degraded → 問題 7 参照
   - Faulted → 問題 3 参照、または Velero バックアップからリストア
