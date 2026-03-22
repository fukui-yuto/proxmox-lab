packer {
  required_plugins {
    proxmox = {
      version = "~> 1.1"
      source  = "github.com/hashicorp/proxmox"
    }
  }
}

variable "proxmox_url"      { default = "https://192.168.210.11:8006/api2/json" }
variable "proxmox_username" { default = "root@pam" }
variable "proxmox_password" { sensitive = true }
variable "ssh_public_key"   {}
variable "template_vm_id"   { default = "9000" }

source "proxmox-iso" "ubuntu-2404" {
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_username
  password                 = var.proxmox_password
  insecure_skip_tls_verify = true
  node                     = "pve-node01"
  vm_id                    = var.template_vm_id
  vm_name                  = "ubuntu-2404-template"

  iso_url          = "https://releases.ubuntu.com/24.04/ubuntu-24.04.2-live-server-amd64.iso"
  iso_checksum     = "file:https://releases.ubuntu.com/24.04/SHA256SUMS"
  iso_storage_pool = "local"

  cores  = 2
  memory = 2048

  network_adapters {
    model  = "virtio"
    bridge = "vmbr0"
  }

  disks {
    disk_size    = "20G"
    storage_pool = "data-pve-node01"
    type         = "virtio"
  }

  cloud_init              = true
  cloud_init_storage_pool = "data-pve-node01"

  # Ubuntu autoinstall (subiquity)
  http_content = {
    "/meta-data" = ""
    "/user-data" = templatefile("${path.root}/http/user-data.yml", {
      ssh_public_key = var.ssh_public_key
    })
  }

  boot_command = [
    "<spacebar><wait>",
    "linux /casper/vmlinuz --- autoinstall ds='nocloud-net;s=http://{{.HTTPIP}}:{{.HTTPPort}}/'<enter><wait>",
    "initrd /casper/initrd<enter><wait>",
    "boot<enter>"
  ]

  ssh_username = "ubuntu"
  ssh_private_key_file = "~/.ssh/id_ed25519"
  ssh_timeout  = "30m"
}

build {
  sources = ["source.proxmox-iso.ubuntu-2404"]

  provisioner "shell" {
    inline = [
      "sudo apt-get update",
      "sudo apt-get install -y qemu-guest-agent cloud-init",
      "sudo systemctl enable qemu-guest-agent",
      "sudo cloud-init clean",
      "sudo truncate -s 0 /etc/machine-id",
    ]
  }
}
