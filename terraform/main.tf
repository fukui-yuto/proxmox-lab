terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"
    }
  }
}

provider "proxmox" {
  endpoint = "https://192.168.210.11:8006"
  username = "root@pam"
  password = var.proxmox_password
  insecure = true  # 自己署名証明書の場合
}

# k3s マスターノード
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
    dedicated = 2048
  }

  network_device {
    bridge = "vmbr0"
    vlan_id = 10
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
        address = "192.168.211.21/24"
        gateway = "192.168.211.1"
      }
    }
    user_account {
      username = "ubuntu"
      keys     = [var.ssh_public_key]
    }
  }
}

# k3s ワーカー × 2 (テンプレートとZFSがnode01のみのため両方node01に配置)
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
    bridge  = "vmbr0"
    vlan_id = 10
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
        address = "192.168.211.2${count.index + 2}/24"
        gateway = "192.168.211.1"
      }
    }
    user_account {
      username = "ubuntu"
      keys     = [var.ssh_public_key]
    }
  }
}

# k3s ワーカー (node02) ※ ZFS なしのため local-lvm を使用
resource "proxmox_virtual_environment_vm" "k3s_worker_node02" {
  name      = "k3s-worker03"
  node_name = "pve-node02"
  vm_id     = 204

  clone {
    vm_id        = var.ubuntu_template_id
    node_name    = "pve-node01"   # テンプレートが node01 にあるため明示
    datastore_id = "local-lvm"    # node02 に ZFS がないため local-lvm に強制
  }

  cpu {
    cores = 1
    type  = "host"
  }

  memory {
    dedicated = 2048
  }

  network_device {
    bridge  = "vmbr0"
    vlan_id = 10
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
        address = "192.168.211.24/24"
        gateway = "192.168.211.2"  # node02 の VLAN10 ブリッジ (node01 は L2 未到達)
      }
    }
    user_account {
      username = "ubuntu"
      keys     = [var.ssh_public_key]
    }
  }

  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      user        = "ubuntu"
      host        = "192.168.211.24"
      private_key = file("~/.ssh/id_ed25519")
      timeout     = "3m"
    }

    inline = [
      "if [ -n '${var.k3s_token}' ]; then curl -sfL https://get.k3s.io | K3S_URL=https://192.168.211.21:6443 K3S_TOKEN=${var.k3s_token} sh -; else echo 'k3s_token が未設定のため k3s 参加をスキップ'; fi"
    ]
  }
}

# Pi-hole DNS (LXC コンテナ)
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
