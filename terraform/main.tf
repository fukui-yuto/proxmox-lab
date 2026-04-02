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
  gateway     = "192.168.210.254"
  dns_servers = ["192.168.210.254", "8.8.8.8"]
  master_ip   = "192.168.210.21"
  ssh_key     = "~/.ssh/id_ed25519"
  # worker01〜05 の IP (インデックス順)
  worker_ips = [
    "192.168.210.22", # worker01 (node01)
    "192.168.210.23", # worker02 (node01)
    "192.168.210.24", # worker03 (node02)
    "192.168.210.25", # worker04 (node02)
    "192.168.210.26", # worker05 (node02)
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
# k3s ワーカー × 2 (テンプレートとZFSがnode01のみのため両方node01に配置)
# -------------------------------------------------------------------
resource "proxmox_virtual_environment_vm" "k3s_worker" {
  count     = 2
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

# k3s worker01〜05 インストール (全ワーカー共通)
# worker01/02: k3s_worker[0/1]、worker03/04/05: k3s_worker_node02[0/1/2]
resource "null_resource" "k3s_workers_install" {
  count = 5
  triggers = {
    vm_id = count.index < 2 ? proxmox_virtual_environment_vm.k3s_worker[count.index].id : proxmox_virtual_environment_vm.k3s_worker_node02[count.index - 2].id
  }
  depends_on = [
    null_resource.k3s_master_install,
    proxmox_virtual_environment_vm.k3s_worker,
    proxmox_virtual_environment_vm.k3s_worker_node02,
  ]

  connection {
    type        = "ssh"
    user        = "ubuntu"
    host        = local.worker_ips[count.index]
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

# state 移行: k3s_worker_node02_install[0/1/2] → k3s_workers_install[2/3/4]
moved {
  from = null_resource.k3s_worker_node02_install[0]
  to   = null_resource.k3s_workers_install[2]
}
moved {
  from = null_resource.k3s_worker_node02_install[1]
  to   = null_resource.k3s_workers_install[3]
}
moved {
  from = null_resource.k3s_worker_node02_install[2]
  to   = null_resource.k3s_workers_install[4]
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
