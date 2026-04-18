terraform {
  required_version = ">= 1.5"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

locals {
  gateway                  = "192.168.210.254"
  dns_servers              = ["192.168.210.53", "8.8.8.8"]  # Pi-hole (dns-ct) を優先 DNS に設定
  master_ip                = "192.168.210.21"
  ssh_key                  = "~/.ssh/id_ed25519"
  worker_node03_disk_size  = 50  # worker06〜09 のディスクサイズ (GB)
  # worker01〜09 の IP (インデックス順)
  worker_ips = [
    "192.168.210.22", # worker01 (node01)
    "192.168.210.23", # worker02 (node01) — VM 203 は削除済み。インデックスを維持するため残す
    "192.168.210.24", # worker03 (node02)
    "192.168.210.25", # worker04 (node02)
    "192.168.210.26", # worker05 (node02)
    "192.168.210.27", # worker06 (node03)
    "192.168.210.28", # worker07 (node03)
    "192.168.210.29", # worker08 (node03)
    "192.168.210.30", # worker09 (node03)
  ]
}

provider "proxmox" {
  endpoint = "https://192.168.210.11:8006"
  username = "root@pam"
  password = var.proxmox_password
  insecure = true  # 自己署名証明書の場合
}

# k3s クラスタートークン (自動生成)
resource "random_password" "k3s_token" {
  length  = 48
  special = false
}

# -------------------------------------------------------------------
# k3s マスターノード
# -------------------------------------------------------------------
resource "proxmox_virtual_environment_vm" "k3s_master" {
  name      = "k3s-master"
  node_name = "pve-node01"
  vm_id     = 201

  clone {
    vm_id = var.ubuntu_template_id
  }

  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 6144
  }

  network_device {
    bridge = "vmbr0"
  }

  disk {
    datastore_id = "data-pve-node01"
    size         = 20
    interface    = "virtio0"
  }

  initialization {
    dns {
      servers = local.dns_servers
    }
    ip_config {
      ipv4 {
        address = "${local.master_ip}/24"
        gateway = local.gateway
      }
    }
    user_account {
      username = "ubuntu"
      keys     = [var.ssh_public_key]
    }
  }
}

# -------------------------------------------------------------------
# k3s ワーカー × 1 (テンプレートとZFSがnode01のみのためnode01に配置)
# -------------------------------------------------------------------
resource "proxmox_virtual_environment_vm" "k3s_worker" {
  count     = 1
  name      = "k3s-worker0${count.index + 1}"
  node_name = "pve-node01"
  vm_id     = 202 + count.index

  clone {
    vm_id = var.ubuntu_template_id
  }

  cpu {
    cores = 1
    type  = "host"
  }

  memory {
    dedicated = 4096
  }

  network_device {
    bridge = "vmbr0"
  }

  disk {
    datastore_id = "data-pve-node01"
    size         = 20
    interface    = "virtio0"
  }

  initialization {
    dns {
      servers = local.dns_servers
    }
    ip_config {
      ipv4 {
        address = "${local.worker_ips[count.index]}/24"
        gateway = local.gateway
      }
    }
    user_account {
      username = "ubuntu"
      keys     = [var.ssh_public_key]
    }
  }
}

# -------------------------------------------------------------------
# node02 用テンプレート (node01 の 9000 を vzdump → restore で複製)
# cross-node clone + migration を回避し、同ノードクローンにする
# -------------------------------------------------------------------
resource "null_resource" "node02_template" {
  triggers = {
    source_template = var.ubuntu_template_id
  }

  provisioner "local-exec" {
    command = <<-EOT
      if ssh -o StrictHostKeyChecking=no root@192.168.210.12 'qm config 9001' > /dev/null 2>&1; then
        echo "Template 9001 already exists on pve-node02, skipping."
        exit 0
      fi
      echo "Creating template 9001 on pve-node02 via vzdump/restore..."
      ssh -o StrictHostKeyChecking=no root@192.168.210.11 \
        "vzdump ${var.ubuntu_template_id} --storage local --compress zstd --mode stop"
      BACKUP=$(ssh -o StrictHostKeyChecking=no root@192.168.210.11 \
        "ls -t /var/lib/vz/dump/vzdump-qemu-${var.ubuntu_template_id}-*.vma.zst | head -1")
      FILENAME=$(basename "$BACKUP")
      ssh -o StrictHostKeyChecking=no root@192.168.210.11 \
        "scp -o StrictHostKeyChecking=no $BACKUP root@192.168.210.12:/var/lib/vz/dump/"
      ssh -o StrictHostKeyChecking=no root@192.168.210.12 \
        "qmrestore /var/lib/vz/dump/$FILENAME 9001 --storage local-lvm && qm template 9001"
      ssh -o StrictHostKeyChecking=no root@192.168.210.11 "rm -f $BACKUP"
      ssh -o StrictHostKeyChecking=no root@192.168.210.12 "rm -f /var/lib/vz/dump/$FILENAME"
      echo "Template 9001 created on pve-node02."
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = "ssh -o StrictHostKeyChecking=no root@192.168.210.12 'qm destroy 9001 --purge 2>/dev/null'; exit 0"
  }
}

# -------------------------------------------------------------------
# node03 用テンプレート (node01 の 9000 を vzdump → restore で複製)
# -------------------------------------------------------------------
resource "null_resource" "node03_template" {
  triggers = {
    source_template = var.ubuntu_template_id
  }

  provisioner "local-exec" {
    command = <<-EOT
      if ssh -o StrictHostKeyChecking=no root@192.168.210.13 'qm config 9002' > /dev/null 2>&1; then
        echo "Template 9002 already exists on pve-node03, skipping."
        exit 0
      fi
      echo "Enabling images content on local storage of pve-node03..."
      ssh -o StrictHostKeyChecking=no root@192.168.210.13 \
        "pvesm set local --content iso,vztmpl,backup,images,rootdir"
      echo "Creating template 9002 on pve-node03 via vzdump/restore..."
      ssh -o StrictHostKeyChecking=no root@192.168.210.11 \
        "vzdump ${var.ubuntu_template_id} --storage local --compress zstd --mode stop"
      BACKUP=$(ssh -o StrictHostKeyChecking=no root@192.168.210.11 \
        "ls -t /var/lib/vz/dump/vzdump-qemu-${var.ubuntu_template_id}-*.vma.zst | head -1")
      FILENAME=$(basename "$BACKUP")
      ssh -o StrictHostKeyChecking=no root@192.168.210.11 \
        "scp -o StrictHostKeyChecking=no $BACKUP root@192.168.210.13:/var/lib/vz/dump/"
      ssh -o StrictHostKeyChecking=no root@192.168.210.13 \
        "qmrestore /var/lib/vz/dump/$FILENAME 9002 --storage local && qm template 9002"
      ssh -o StrictHostKeyChecking=no root@192.168.210.11 "rm -f $BACKUP"
      ssh -o StrictHostKeyChecking=no root@192.168.210.13 "rm -f /var/lib/vz/dump/$FILENAME"
      echo "Template 9002 created on pve-node03."
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = "ssh -o StrictHostKeyChecking=no root@192.168.210.13 'qm destroy 9002 --purge 2>/dev/null'; exit 0"
  }
}

# -------------------------------------------------------------------
# k3s ワーカー (node02 × 3: worker03/04/05) ※ ZFS なしのため local-lvm を使用
# -------------------------------------------------------------------
resource "proxmox_virtual_environment_vm" "k3s_worker_node02" {
  count     = 3
  name      = "k3s-worker0${count.index + 3}"
  node_name = "pve-node02"
  vm_id     = 204 + count.index

  depends_on = [null_resource.node02_template]

  clone {
    vm_id        = 9001
    datastore_id = "local-lvm"
  }

  cpu {
    cores = 1
    type  = "host"
  }

  memory {
    dedicated = 4096
  }

  network_device {
    bridge = "vmbr0"
  }

  disk {
    datastore_id = "local-lvm"
    size         = 20
    interface    = "virtio0"
  }

  initialization {
    dns {
      servers = local.dns_servers
    }
    ip_config {
      ipv4 {
        address = "${local.worker_ips[count.index + 2]}/24"
        gateway = local.gateway
      }
    }
    user_account {
      username = "ubuntu"
      keys     = [var.ssh_public_key]
    }
  }

  # destroy 時: pve-node02 が data-pve-node01 (ZFS) を参照してエラーになるため
  # Proxmox API より先に qm destroy --purge で手動削除する
  provisioner "local-exec" {
    when    = destroy
    command = "ssh -o StrictHostKeyChecking=no root@192.168.210.12 'qm stop ${self.vm_id} --skiplock 2>/dev/null; qm destroy ${self.vm_id} --skiplock --purge 2>/dev/null'; exit 0"
  }
}

# -------------------------------------------------------------------
# k3s ワーカー (node03 × 4: worker06/07/08/09) ※ local (dir) ストレージを使用
# -------------------------------------------------------------------
resource "proxmox_virtual_environment_vm" "k3s_worker_node03" {
  count     = 4
  name      = "k3s-worker0${count.index + 6}"
  node_name = "pve-node03"
  vm_id     = 207 + count.index

  depends_on = [null_resource.node03_template]

  clone {
    vm_id        = 9002
    datastore_id = "local"
  }

  cpu {
    cores = 1
    type  = "host"
  }

  memory {
    dedicated = 4096
  }

  network_device {
    bridge = "vmbr0"
  }

  disk {
    datastore_id = "local"
    size         = local.worker_node03_disk_size
    interface    = "virtio0"
    file_format  = "qcow2"
  }

  initialization {
    datastore_id = "local"
    dns {
      servers = local.dns_servers
    }
    ip_config {
      ipv4 {
        address = "${local.worker_ips[count.index + 5]}/24"
        gateway = local.gateway
      }
    }
    user_account {
      username = "ubuntu"
      keys     = [var.ssh_public_key]
    }
  }

  provisioner "local-exec" {
    when    = destroy
    command = "ssh -o StrictHostKeyChecking=no root@192.168.210.13 'qm stop ${self.vm_id} --skiplock 2>/dev/null; qm destroy ${self.vm_id} --skiplock --purge 2>/dev/null'; exit 0"
  }
}

# -------------------------------------------------------------------
# node03 ワーカーのディスク拡張 (サイズ変更時に自動実行)
# -------------------------------------------------------------------
resource "null_resource" "expand_disk_node03" {
  count = 4

  triggers = {
    disk_size = local.worker_node03_disk_size
  }

  depends_on = [proxmox_virtual_environment_vm.k3s_worker_node03]

  # Step 1: Proxmox 側でディスクサイズを拡張 (qm resize)
  provisioner "local-exec" {
    command = "ssh -o StrictHostKeyChecking=no root@192.168.210.13 'qm resize ${207 + count.index} virtio0 ${local.worker_node03_disk_size}G'"
  }

  # Step 2: VM 内でパーティション・ファイルシステムを拡張
  connection {
    type        = "ssh"
    user        = "ubuntu"
    host        = local.worker_ips[count.index + 5]
    private_key = file(local.ssh_key)
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = [
      "sudo apt-get install -y cloud-guest-utils",
      "sudo growpart /dev/vda 2 || true",
      "sudo resize2fs /dev/vda2",
    ]
  }
}

# -------------------------------------------------------------------
# k3s インストール
# -------------------------------------------------------------------

# k3s master インストール
resource "null_resource" "k3s_master_install" {
  triggers = {
    vm_id = proxmox_virtual_environment_vm.k3s_master.id
  }
  depends_on = [proxmox_virtual_environment_vm.k3s_master]

  connection {
    type        = "ssh"
    user        = "ubuntu"
    host        = local.master_ip
    private_key = file(local.ssh_key)
    timeout     = "10m"
  }

  # フェーズ1: k3s トークンをファイルに書き込む (sensitive のため出力抑制)
  provisioner "remote-exec" {
    inline = [
      "printf '%s' '${random_password.k3s_token.result}' | sudo tee /run/k3s-token > /dev/null"
    ]
  }

  # フェーズ2: cloud-init 待機・k3s インストール (出力が見える)
  provisioner "remote-exec" {
    inline = [
      "cloud-init status --wait || true",
      "sudo hostnamectl set-hostname k3s-master",
      "sudo k3s-uninstall.sh 2>/dev/null || true",
      "export K3S_TOKEN=$(sudo cat /run/k3s-token) && K3S_NODE_NAME=k3s-master curl -sfL https://get.k3s.io | sh -",
      "sudo rm -f /run/k3s-token",
      "sleep 60",
      "sudo k3s kubectl wait --for=condition=Ready node/k3s-master --timeout=120s"
    ]
  }
}

# k3s worker01,03〜09 インストール (全ワーカー共通、worker02 は削除済み)
# worker01: k3s_worker[0]、worker03/04/05: k3s_worker_node02[0/1/2]、worker06〜09: k3s_worker_node03[0/1/2/3]
# count インデックスと worker_ips のマッピング (index 1 = worker02 はスキップ):
#   count 0 → worker_ips[0] (worker01)
#   count 1 → worker_ips[2] (worker03)  ※ worker02(index 1) をスキップするため +1
#   count 2 → worker_ips[3] (worker04)
#   ...
resource "null_resource" "k3s_workers_install" {
  count = 8
  triggers = {
    vm_id = count.index < 1 ? proxmox_virtual_environment_vm.k3s_worker[count.index].id : count.index < 4 ? proxmox_virtual_environment_vm.k3s_worker_node02[count.index - 1].id : proxmox_virtual_environment_vm.k3s_worker_node03[count.index - 4].id
  }
  depends_on = [
    null_resource.k3s_master_install,
    proxmox_virtual_environment_vm.k3s_worker,
    proxmox_virtual_environment_vm.k3s_worker_node02,
    proxmox_virtual_environment_vm.k3s_worker_node03,
  ]

  connection {
    type        = "ssh"
    user        = "ubuntu"
    host        = local.worker_ips[count.index > 0 ? count.index + 1 : 0]
    private_key = file(local.ssh_key)
    timeout     = "10m"
  }

  provisioner "remote-exec" {
    inline = [
      "echo 'ipv4' | sudo tee /etc/curlrc",
      "curl -sfL https://get.k3s.io | K3S_URL=https://${local.master_ip}:6443 K3S_TOKEN=${random_password.k3s_token.result} sh -"
    ]
  }
}

# kubeconfig を Raspberry Pi に配置
resource "null_resource" "kubeconfig_setup" {
  triggers = {
    k3s_master_install_id = null_resource.k3s_master_install.id
  }
  depends_on = [null_resource.k3s_master_install]

  provisioner "local-exec" {
    command = <<-EOT
      mkdir -p ~/.kube
      ssh -o StrictHostKeyChecking=no ubuntu@${local.master_ip} 'sudo cat /etc/rancher/k3s/k3s.yaml' > ~/.kube/config
      sed -i 's/127.0.0.1/${local.master_ip}/g' ~/.kube/config
    EOT
  }
}

# -------------------------------------------------------------------
# Pi-hole DNS (LXC コンテナ)
# -------------------------------------------------------------------
resource "proxmox_virtual_environment_container" "pihole" {
  description = "Pi-hole DNS"
  node_name   = "pve-node01"
  vm_id       = 101

  initialization {
    hostname = "dns-ct"
    ip_config {
      ipv4 {
        address = "192.168.210.53/24"
        gateway = local.gateway
      }
    }
    user_account {
      password = var.ct_root_password
      keys     = [var.ssh_public_key]
    }
  }

  cpu {
    cores = 1
  }

  memory {
    dedicated = 512
  }

  disk {
    datastore_id = "data-pve-node01"
    size         = 8
  }

  network_interface {
    name   = "eth0"
    bridge = "vmbr0"
  }

  operating_system {
    template_file_id = var.debian_ct_template
    type             = "debian"
  }
}

# -------------------------------------------------------------------
# k3s レジストリ設定 (Harbor など社内レジストリの insecure/エンドポイント設定)
# registries.yaml を全 k3s ノードに配布し k3s/k3s-agent を再起動する。
# レジストリ設定を変更した場合は registry_config_version をインクリメントする。
# -------------------------------------------------------------------
resource "null_resource" "k3s_registry_config" {
  triggers = {
    # バージョンを上げると全ノードで再適用される
    registry_config_version = "5"
  }

  depends_on = [null_resource.k3s_workers_install]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      INGRESS_IP="192.168.210.24"
      CONTENT='mirrors:\n  harbor.homelab.local:\n    endpoint:\n      - "http://harbor.homelab.local"\nconfigs:\n  "harbor.homelab.local":\n    tls:\n      insecure_skip_verify: true'

      # Traefik Ingress 経由でアクセスするホームラボサービス
      # containerd が Pi-hole DNS に依存せずイメージプルできるように /etc/hosts に追記する
      HOMELAB_HOSTS=(
        harbor.homelab.local
        grafana.homelab.local
        kibana.homelab.local
        argocd.homelab.local
        argo-workflows.homelab.local
        alert-summarizer.homelab.local
        elasticsearch.homelab.local
        keycloak.homelab.local
        vault.homelab.local
      )

      apply_registry() {
        local ip="$1"
        local service="$2"
        echo "==> Configuring registry on $ip (service: $service)"
        ssh -o StrictHostKeyChecking=no ubuntu@"$ip" \
          "sudo mkdir -p /etc/rancher/k3s && printf '$CONTENT\n' | sudo tee /etc/rancher/k3s/registries.yaml > /dev/null && sudo systemctl restart $service && echo 'registry done'"
        for host in "$${HOMELAB_HOSTS[@]}"; do
          ssh -o StrictHostKeyChecking=no ubuntu@"$ip" \
            "grep -qF '$INGRESS_IP $host' /etc/hosts || echo '$INGRESS_IP $host' | sudo tee -a /etc/hosts"
        done
        echo "  hosts done: $ip"
      }

      apply_registry 192.168.210.21 k3s
      for ip in 192.168.210.22 192.168.210.24 192.168.210.25 192.168.210.26 192.168.210.27 192.168.210.28 192.168.210.29 192.168.210.30; do
        apply_registry "$ip" k3s-agent
      done
      echo "Registry config applied to all nodes."
    EOT
  }
}

# -------------------------------------------------------------------
# Falco 用 sysctl チューニング
# modern_ebpf ドライバーは perf_event_open() を使用するため
# perf_event_paranoid を 1 に下げる必要がある。
# Ubuntu 24.04 のデフォルト (4) では scap_init が失敗する。
# sysctl_falco_version を上げると全ノードで再適用される。
# -------------------------------------------------------------------
# -------------------------------------------------------------------
# k3s flannel 無効化 → Cilium CNI 移行
# flannel_disable_version を上げると再実行される。
# 実行後に k3s-master が再起動し、cilium が CNI を引き継ぐ。
# -------------------------------------------------------------------
resource "null_resource" "k3s_disable_flannel" {
  triggers = {
    flannel_disable_version = "1"
  }

  depends_on = [null_resource.k3s_master_install]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      echo "==> Disabling flannel on k3s-master (192.168.210.21)"
      ssh -o StrictHostKeyChecking=no ubuntu@192.168.210.21 \
        "sudo mkdir -p /etc/rancher/k3s/config.yaml.d && printf 'flannel-backend: none\ndisable-network-policy: true\n' | sudo tee /etc/rancher/k3s/config.yaml.d/00-cilium.yaml && sudo systemctl restart k3s && sleep 30 && sudo k3s kubectl get nodes"
      echo "==> flannel disabled, k3s restarted"
    EOT
  }
}

# -------------------------------------------------------------------
# k3s servicelb (klipper-lb) 無効化
# Cilium kube-proxy replacement 使用時、klipper-lb の HostPort が
# Cilium の LoadBalancer BPF エントリと競合して port 80 が閉塞するため無効化する。
# 無効化後は Traefik の spec.externalIPs (HelmChartConfig で設定) を
# Cilium が直接 BPF で処理する。
# servicelb_disable_version を上げると再実行される。
# -------------------------------------------------------------------
resource "null_resource" "k3s_disable_servicelb" {
  triggers = {
    servicelb_disable_version = "1"
  }

  depends_on = [null_resource.k3s_disable_flannel]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      echo "==> Step 1: Applying Traefik HelmChartConfig (externalIPs) via kubectl"
      kubectl apply -f ~/proxmox-lab/k8s/traefik/helmchartconfig.yaml
      echo "==> Step 2: Disabling k3s servicelb on master"
      ssh -o StrictHostKeyChecking=no ubuntu@192.168.210.21 \
        "printf 'disable:\n  - servicelb\n' | sudo tee /etc/rancher/k3s/config.yaml.d/01-disable-servicelb.yaml && sudo systemctl restart k3s"
      echo "==> Step 3: Waiting for k3s restart to complete"
      sleep 40
      ssh -o StrictHostKeyChecking=no ubuntu@192.168.210.21 "sudo k3s kubectl get nodes"
      echo "==> servicelb disabled, k3s restarted successfully"
    EOT
  }
}

resource "null_resource" "k3s_sysctl_falco" {
  triggers = {
    sysctl_falco_version = "2"
  }

  depends_on = [null_resource.k3s_workers_install]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e

      apply_sysctl() {
        local ip="$1"
        echo "==> Applying Falco sysctl on $ip"
        ssh -o StrictHostKeyChecking=no ubuntu@"$ip" \
          "printf 'kernel.perf_event_paranoid=1\nkernel.unprivileged_bpf_disabled=1\n' | sudo tee /etc/sysctl.d/99-falco.conf && sudo sysctl --system && sysctl kernel.perf_event_paranoid kernel.unprivileged_bpf_disabled && echo 'sysctl done'"
      }

      apply_sysctl 192.168.210.21
      for ip in 192.168.210.22 192.168.210.24 192.168.210.25 192.168.210.26 192.168.210.27 192.168.210.28 192.168.210.29 192.168.210.30; do
        apply_sysctl "$ip"
      done
      echo "Falco sysctl applied to all k3s nodes."
    EOT
  }
}
