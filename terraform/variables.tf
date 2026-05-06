variable "aws_region" {
  description = <<-EOT
    AWS region to deploy in. Default eu-north-1 (Stockholm) — for users in
    Russia/CIS in 2026 it has lighter TSPU throttling on its IP ranges
    than eu-central-1 (Frankfurt). For users in Western Europe, set
    eu-west-1 (Ireland). See docs/russia-whitelist-era.md.

    Note on switching regions on an EXISTING deployment: changing this
    forces Terraform to destroy the EC2 + EIP and re-create them in the
    new region. You'll get a new public IP and (because user_data re-runs
    on a fresh instance) new Reality keys, so every VLESS / AmneziaWG
    link becomes invalid. If you don't want that, pin the old region
    explicitly in terraform/terraform.tfvars.
  EOT
  type        = string
  default     = "eu-north-1"
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
  description = <<-EOT
    Domain to mimic for Reality TLS fingerprint. Default is dzen.ru — a
    large RU-domestic site that is always reachable from inside Russia
    (which is where most users of this project actually are) and has a
    typical TLS 1.3 handshake. See docs/russia-whitelist-era.md for why
    this matters in 2026.

    Other reasonable picks:
      - In-RU domestic (good if your users are there):
          dzen.ru (default), www.kinopoisk.ru, lenta.ru
      - CDN-backed, globally reachable:
          www.microsoft.com, www.bing.com, www.apple.com, swcdn.apple.com
    Avoid www.vk.com (atypical TLS, hurts Reality mimicry).
  EOT
  type        = string
  default     = "dzen.ru"
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

# --- Tailscale (optional) ---
# When this is set to a non-empty auth key, the VPS joins your tailnet on first
# boot and public SSH (port 22) is removed from the security group — you then
# SSH in over Tailscale instead of the public EIP. Leave empty to disable.
#
# Generate a reusable, ephemeral, pre-approved auth key in the Tailscale admin
# console:  https://login.tailscale.com/admin/settings/keys
# Recommended flags: Reusable=off, Ephemeral=off, Pre-approved=on, tag=tag:lazy-vps
# Set via environment:
#   export TF_VAR_tailscale_auth_key='tskey-auth-XXXX-YYYY'

variable "tailscale_auth_key" {
  description = "Tailscale auth key. Empty = Tailscale disabled (default). Non-empty = VPS joins tailnet and public SSH is closed."
  type        = string
  sensitive   = true
  default     = ""
}

variable "tailscale_hostname" {
  description = "Hostname the VPS registers in your tailnet (MagicDNS). Only used when tailscale_auth_key is set."
  type        = string
  default     = "lazy-vps"
}

variable "tailscale_tags" {
  description = "Tailscale ACL tags to apply to the VPS, e.g. [\"tag:lazy-vps\"]. Only used when tailscale_auth_key is set. Tags must be declared in your tailnet policy."
  type        = list(string)
  default     = []
}

# --- AmneziaWG (optional) ---
# AmneziaWG is the obfuscated WireGuard fork from the Amnezia VPN project.
# It adds packet-shape randomisation (Jc / Jmin / Jmax junk packets and
# S1/S2 init/response header padding) that defeats the standard WireGuard
# DPI fingerprint, while keeping WireGuard's performance characteristics.
#
# Off by default. Enable by setting TF_VAR_amnezia_enabled=true. When
# enabled, the VPS opens UDP/<amnezia_port> in the security group on first
# deploy, installs AmneziaWG via the official PPA, generates a server
# keypair plus a single client config, and writes a vpn:// import URI for
# the Amnezia client app.
#
# AmneziaWG is intended as a *secondary* transport alongside Reality, not
# a replacement. See README "Amnezia VPN (optional)".

variable "amnezia_enabled" {
  description = "Enable AmneziaWG (obfuscated WireGuard) on the VPS. Default: false."
  type        = bool
  default     = false
}

variable "amnezia_port" {
  description = "UDP port AmneziaWG listens on. Default 51820 (the WireGuard well-known port)."
  type        = number
  default     = 51820
}

# Obfuscation parameters. Defaults below are the values the official
# Amnezia client ships in its "AmneziaWG (default)" profile circa 2026.
# Don't tweak unless you know why — mismatched server/client values mean
# the tunnel won't come up at all.

variable "amnezia_jc" {
  description = "AmneziaWG Jc: number of junk packets sent at handshake. Default 4."
  type        = number
  default     = 4
}

variable "amnezia_jmin" {
  description = "AmneziaWG Jmin: minimum junk packet size. Default 40."
  type        = number
  default     = 40
}

variable "amnezia_jmax" {
  description = "AmneziaWG Jmax: maximum junk packet size. Default 70."
  type        = number
  default     = 70
}

variable "amnezia_s1" {
  description = "AmneziaWG S1: init-packet header padding bytes. Default 0 (per upstream Amnezia 2.x guidance)."
  type        = number
  default     = 0
}

variable "amnezia_s2" {
  description = "AmneziaWG S2: response-packet header padding bytes. Default 0."
  type        = number
  default     = 0
}

# --- Cloudflare-fronted VLESS-WS (optional) ---
# Adds a *second* VLESS inbound on the VPS that listens for plain HTTP
# WebSocket traffic on an internal port. Cloudflare terminates TLS on
# its edge for `cloudflare_domain` and proxies WebSocket frames to the
# VPS. From TSPU's point of view, traffic to your VPS is just a TLS
# connection to a Cloudflare anycast IP — indistinguishable from any
# other Cloudflare-hosted site, so blocking it requires blocking
# Cloudflare itself.
#
# Off by default. Enable by setting TF_VAR_cloudflare_enabled=true and
# TF_VAR_cloudflare_domain to your proxied subdomain. See README
# "Cloudflare-fronted VLESS (optional)" for the one-time DNS setup.
#
# This is a *secondary* transport — the existing Reality inbound stays
# on. Clients get both links and use whichever is faster on their
# network.

variable "cloudflare_enabled" {
  description = "Enable Cloudflare-fronted VLESS-over-WebSocket. Default: false."
  type        = bool
  default     = false
}

variable "cloudflare_domain" {
  description = <<-EOT
    Subdomain to expose VLESS-WS on, e.g. connect.lazy-vps.com. Must be
    a "Proxied" record in your Cloudflare dashboard pointing at the VPS
    Elastic IP. Required when cloudflare_enabled=true; ignored otherwise.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = !var.cloudflare_enabled || length(var.cloudflare_domain) > 0
    error_message = "cloudflare_domain must be set when cloudflare_enabled=true. Set TF_VAR_cloudflare_domain, e.g. 'connect.lazy-vps.com'."
  }
}

variable "cloudflare_ws_path" {
  description = <<-EOT
    URL path the VLESS-WS endpoint listens on. Acts as a soft
    password — anyone hitting cloudflare_domain at the wrong path gets
    a 404 from Xray and the connection looks like an inert visit to
    a (probably) static site. Default: /<random hex>.
  EOT
  type        = string
  default     = ""
}
