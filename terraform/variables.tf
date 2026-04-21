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

# --- Telegram Bot ---
# Both variables below are sourced from environment variables:
#   export TF_VAR_telegram_bot_token='123456:ABCDEF...'
#   export TF_VAR_telegram_allowed_users='["alice","bob","123456789"]'
# Terraform reads any TF_VAR_<name> automatically.

variable "telegram_bot_token" {
  description = "Telegram bot token from @BotFather (set via TF_VAR_telegram_bot_token)"
  type        = string
  sensitive   = true
}

variable "telegram_allowed_users" {
  description = <<-EOT
    List of Telegram users allowed to use the bot. Each entry may be:
      - a numeric Telegram user ID (e.g. "123456789")
      - a username, with or without leading '@' (e.g. "alice" or "@alice")
    Usernames match case-insensitively. Set via TF_VAR_telegram_allowed_users
    as a JSON array, e.g. '["alice","bob","123456789"]'.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.telegram_allowed_users) > 0
    error_message = "telegram_allowed_users must not be empty. Set TF_VAR_telegram_allowed_users, e.g. '[\"alice\",\"123456789\"]'."
  }
}
