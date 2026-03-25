# packer/

Proxmox 上に Ubuntu 24.04 VM テンプレートをビルドする Packer 設定。

---

## Ubuntu テンプレートのビルド

```bash
cd ~/proxmox-lab/packer

packer init ubuntu-2404.pkr.hcl

packer build \
  -var "proxmox_password=<rootパスワード>" \
  -var "ssh_public_key=$(cat ~/.ssh/id_ed25519.pub)" \
  ubuntu-2404.pkr.hcl
```

完了すると Proxmox 上に VM ID `9000` のテンプレートが作成される。

---

## 事前準備: パスワードハッシュの生成

`packer/http/user-data.yml` の Ubuntu ユーザーパスワードはハッシュ形式で記述する。

```bash
# ハッシュを生成
openssl passwd -6 "任意のパスワード"
```

出力されたハッシュを `user-data.yml` の該当箇所に貼り付ける:

```yaml
password: "$6$rounds=4096$xxxxxx..."  # ← ここに貼り付け
```
