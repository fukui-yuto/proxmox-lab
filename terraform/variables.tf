variable "proxmox_password" {
  description = "Proxmox root パスワード"
  type        = string
  sensitive   = true
}

variable "ssh_public_key" {
  description = "VM に登録する SSH 公開鍵"
  type        = string
}

variable "ubuntu_template_id" {
  description = "Ubuntu Cloud-init テンプレートの VM ID"
  type        = number
  default     = 9000
}

variable "debian_ct_template" {
  description = "Debian LXC テンプレートのストレージパス"
  type        = string
  default     = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
}

variable "ct_root_password" {
  description = "LXC コンテナの root パスワード"
  type        = string
  sensitive   = true
}

variable "k3s_token" {
  description = "k3s サーバートークン (取得: ssh ubuntu@192.168.211.21 'sudo cat /var/lib/rancher/k3s/server/node-token')"
  type        = string
  sensitive   = true
  default     = ""
}
