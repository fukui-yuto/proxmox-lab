terraform {
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
      servers = ["192.168.210.254", "8.8.8.8"]
    }
    ip_config {
      ipv4 {
        address = "192.168.210.21/24"
        gateway = "192.168.210.254"
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
      servers = ["192.168.210.254", "8.8.8.8"]
    }
    ip_config {
      ipv4 {
        address = "192.168.210.2${count.index + 2}/24"
        gateway = "192.168.210.254"
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
# k3s ワーカー (node02) ※ ZFS なしのため local-lvm を使用
# -------------------------------------------------------------------
resource "proxmox_virtual_environment_vm" "k3s_worker_node02" {
  name      = "k3s-worker03"
  node_name = "pve-node02"
  vm_id     = 204

  depends_on = [null_resource.node02_template]

  clone {
    vm_id        = 9001          # node02 のローカルテンプレート (migration 不要)
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
      servers = ["192.168.210.254", "8.8.8.8"]
    }
    ip_config {
      ipv4 {
        address = "192.168.210.24/24"
        gateway = "192.168.210.254"
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
    command = "ssh -o StrictHostKeyChecking=no root@192.168.210.12 'qm stop 204 --skiplock 2>/dev/null; qm destroy 204 --skiplock --purge 2>/dev/null'; exit 0"
  }
}

# -------------------------------------------------------------------
# k3s ワーカー04 (node02) ※ worker03 と同様に local-lvm を使用
# -------------------------------------------------------------------
resource "proxmox_virtual_environment_vm" "k3s_worker04" {
  name      = "k3s-worker04"
  node_name = "pve-node02"
  vm_id     = 205

  depends_on = [null_resource.node02_template]

  clone {
    vm_id        = 9001          # node02 のローカルテンプレート (migration 不要)
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
      servers = ["192.168.210.254", "8.8.8.8"]
    }
    ip_config {
      ipv4 {
        address = "192.168.210.25/24"
        gateway = "192.168.210.254"
      }
    }
    user_account {
      username = "ubuntu"
      keys     = [var.ssh_public_key]
    }
  }

  provisioner "local-exec" {
    when    = destroy
    command = "ssh -o StrictHostKeyChecking=no root@192.168.210.12 'qm stop 205 --skiplock 2>/dev/null; qm destroy 205 --skiplock --purge 2>/dev/null'; exit 0"
  }
}

# -------------------------------------------------------------------
# k3s ワーカー05 (node02) ※ worker03/04 と同様に local-lvm を使用
# -------------------------------------------------------------------
resource "proxmox_virtual_environment_vm" "k3s_worker05" {
  name      = "k3s-worker05"
  node_name = "pve-node02"
  vm_id     = 206

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
      servers = ["192.168.210.254", "8.8.8.8"]
    }
    ip_config {
      ipv4 {
        address = "192.168.210.26/24"
        gateway = "192.168.210.254"
      }
    }
    user_account {
      username = "ubuntu"
      keys     = [var.ssh_public_key]
    }
  }

  provisioner "local-exec" {
    when    = destroy
    command = "ssh -o StrictHostKeyChecking=no root@192.168.210.12 'qm stop 206 --skiplock 2>/dev/null; qm destroy 206 --skiplock --purge 2>/dev/null'; exit 0"
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

  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      user        = "ubuntu"
      host        = "192.168.210.21"
      private_key = file("~/.ssh/id_ed25519")
      timeout     = "10m"
    }
    inline = [
      "curl -sfL https://get.k3s.io | K3S_TOKEN=${random_password.k3s_token.result} sh -",
      "sudo kubectl wait --for=condition=Ready node/k3s-master --timeout=120s"
    ]
  }
}

# k3s worker01 / worker02 インストール
resource "null_resource" "k3s_workers_install" {
  count = 2
  triggers = {
    vm_id = proxmox_virtual_environment_vm.k3s_worker[count.index].id
  }
  depends_on = [
    null_resource.k3s_master_install,
    proxmox_virtual_environment_vm.k3s_worker,
  ]

  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      user        = "ubuntu"
      host        = "192.168.210.2${count.index + 2}"
      private_key = file("~/.ssh/id_ed25519")
      timeout     = "10m"
    }
    inline = [
      "curl -sfL https://get.k3s.io | K3S_URL=https://192.168.210.21:6443 K3S_TOKEN=${random_password.k3s_token.result} sh -"
    ]
  }
}

# k3s worker03 インストール
resource "null_resource" "k3s_worker03_install" {
  triggers = {
    vm_id = proxmox_virtual_environment_vm.k3s_worker_node02.id
  }
  depends_on = [
    null_resource.k3s_master_install,
    proxmox_virtual_environment_vm.k3s_worker_node02,
  ]

  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      user        = "ubuntu"
      host        = "192.168.210.24"
      private_key = file("~/.ssh/id_ed25519")
      timeout     = "10m"
    }
    inline = [
      "curl -sfL https://get.k3s.io | K3S_URL=https://192.168.210.21:6443 K3S_TOKEN=${random_password.k3s_token.result} sh -"
    ]
  }
}

# k3s worker04 インストール
resource "null_resource" "k3s_worker04_install" {
  triggers = {
    vm_id = proxmox_virtual_environment_vm.k3s_worker04.id
  }
  depends_on = [
    null_resource.k3s_master_install,
    proxmox_virtual_environment_vm.k3s_worker04,
  ]

  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      user        = "ubuntu"
      host        = "192.168.210.25"
      private_key = file("~/.ssh/id_ed25519")
      timeout     = "10m"
    }
    inline = [
      "curl -sfL https://get.k3s.io | K3S_URL=https://192.168.210.21:6443 K3S_TOKEN=${random_password.k3s_token.result} sh -"
    ]
  }
}

# k3s worker05 インストール
resource "null_resource" "k3s_worker05_install" {
  triggers = {
    vm_id = proxmox_virtual_environment_vm.k3s_worker05.id
  }
  depends_on = [
    null_resource.k3s_master_install,
    proxmox_virtual_environment_vm.k3s_worker05,
  ]

  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      user        = "ubuntu"
      host        = "192.168.210.26"
      private_key = file("~/.ssh/id_ed25519")
      timeout     = "10m"
    }
    inline = [
      "curl -sfL https://get.k3s.io | K3S_URL=https://192.168.210.21:6443 K3S_TOKEN=${random_password.k3s_token.result} sh -"
    ]
  }
}

# kubeconfig を Raspberry Pi に配置
resource "null_resource" "kubeconfig_setup" {
  triggers = {
    vm_id = proxmox_virtual_environment_vm.k3s_master.id
  }
  depends_on = [null_resource.k3s_master_install]

  provisioner "local-exec" {
    command = <<-EOT
      mkdir -p ~/.kube
      scp -o StrictHostKeyChecking=no ubuntu@192.168.210.21:/etc/rancher/k3s/k3s.yaml ~/.kube/config
      sed -i 's/127.0.0.1/192.168.210.21/g' ~/.kube/config
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
        gateway = "192.168.210.254"
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
