variable "aws_region" {
  description = "AWS region to deploy in"
  type        = string
  default     = "eu-central-1"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.micro"
}

variable "ssh_public_key_path" {
  description = "Path to SSH public key for EC2 access"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "ssh_cidr_blocks" {
  description = "CIDR blocks allowed to SSH (default: anywhere)"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "camouflage_domain" {
  description = "Domain to mimic for Reality TLS fingerprint"
  type        = string
  default     = "www.vk.com"
}

variable "mtproto_port" {
  description = "Port for Telegram MTProto proxy (Telemt)"
  type        = number
  default     = 8443
}

variable "mtproto_mask_domain" {
  description = "Domain that MTProto proxy impersonates during active probing"
  type        = string
  default     = "www.yandex.ru"
}
