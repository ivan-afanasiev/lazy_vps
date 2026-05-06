terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# --- Data Sources ---

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# --- Xray Credentials (generated once, stored in state) ---

resource "random_uuid" "xray_uuid" {}

resource "random_id" "xray_short_id" {
  byte_length = 8
}

# When cloudflare_ws_path isn't pinned by the user, generate a random
# 16-hex-char path. This is a soft password — Xray returns 404 on
# anything else, so probes that don't know the path see what looks
# like a static, mostly-empty website behind the Cloudflare cert.
resource "random_id" "cloudflare_ws_path" {
  byte_length = 8
}

# Cloudflare publishes its IPv4 ranges at a stable URL. Fetch them at
# plan time so we can scope the WS-fronting ingress rule to them and
# only them — your AWS Elastic IP will accept VLESS-WS traffic *only*
# from Cloudflare's edge, not from the open internet. Auto-refreshes
# whenever you re-run `make deploy`.
data "http" "cloudflare_ipv4" {
  count = var.cloudflare_enabled ? 1 : 0
  url   = "https://www.cloudflare.com/ips-v4"
}

locals {
  cloudflare_ipv4_ranges = var.cloudflare_enabled ? compact(split("\n", data.http.cloudflare_ipv4[0].response_body)) : []
  # If the user didn't pin a WS path, fall back to the random one. The
  # random_id always exists (it's cheap and stateless), but we only
  # actually plumb the resulting path into Xray when CF is enabled.
  cloudflare_ws_path_resolved = var.cloudflare_ws_path != "" ? var.cloudflare_ws_path : "/${random_id.cloudflare_ws_path.hex}"
}

# --- Networking ---

resource "aws_security_group" "vps" {
  name        = "lazy-vps-sg"
  description = "Allow SSH and VLESS Reality (443)"

  # Public SSH is only exposed when Tailscale is NOT configured. When you set
  # tailscale_auth_key, SSH goes over the tailnet instead and port 22 is
  # dropped from the public security group entirely.
  dynamic "ingress" {
    for_each = var.tailscale_auth_key == "" ? [1] : []
    content {
      description = "SSH"
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = var.ssh_cidr_blocks
    }
  }

  ingress {
    description = "VLESS Reality"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Telegram MTProto (Telemt)"
    from_port   = var.mtproto_port
    to_port     = var.mtproto_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # AmneziaWG only exposes its UDP port when the feature flag is on. The
  # port is 51820 by default (standard WireGuard) but every other byte on
  # the wire is obfuscated, so DPI can't classify it as WG.
  dynamic "ingress" {
    for_each = var.amnezia_enabled ? [1] : []
    content {
      description = "AmneziaWG (obfuscated WireGuard)"
      from_port   = var.amnezia_port
      to_port     = var.amnezia_port
      protocol    = "udp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  # Cloudflare-fronted VLESS-over-WebSocket. Cloudflare connects to
  # our origin on TCP/8080 in plain HTTP (TLS is terminated at the
  # Cloudflare edge); we lock this rule down to Cloudflare's published
  # IPv4 ranges so nobody else can probe :8080 from the open internet.
  # The user must also add a Cloudflare *Origin Rule* mapping
  # cloudflare_domain to "Origin Port = 8080" — see the README.
  dynamic "ingress" {
    for_each = var.cloudflare_enabled ? [1] : []
    content {
      description = "Cloudflare-fronted VLESS-WS"
      from_port   = 8080
      to_port     = 8080
      protocol    = "tcp"
      cidr_blocks = local.cloudflare_ipv4_ranges
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "lazy-vps"
  }
}

# --- SSH Key ---

resource "aws_key_pair" "ssh" {
  key_name   = "lazy-vps-key"
  public_key = file(pathexpand(var.ssh_public_key_path))
}

# --- IAM Role for EC2 (used by the Telegram bot on the instance) ---

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "vps" {
  name               = "lazy-vps-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = {
    Name = "lazy-vps"
  }
}

# Minimal permissions the bot needs to answer `/traffic`.
# ec2:DescribeInstances does not support resource-level restrictions, so it's "*".
# cloudwatch:GetMetricStatistics also does not support resource-level restrictions.
data "aws_iam_policy_document" "vps_bot" {
  statement {
    sid    = "CloudWatchReadMetrics"
    effect = "Allow"
    actions = [
      "cloudwatch:GetMetricStatistics",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "DescribeOwnInstance"
    effect = "Allow"
    actions = [
      "ec2:DescribeInstances",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "vps_bot" {
  name   = "lazy-vps-bot"
  role   = aws_iam_role.vps.id
  policy = data.aws_iam_policy_document.vps_bot.json
}

resource "aws_iam_instance_profile" "vps" {
  name = "lazy-vps-profile"
  role = aws_iam_role.vps.name
}

# --- EC2 Instance ---

resource "aws_instance" "vps" {
  ami                  = data.aws_ami.ubuntu.id
  instance_type        = var.instance_type
  key_name             = aws_key_pair.ssh.key_name
  iam_instance_profile = aws_iam_instance_profile.vps.name

  vpc_security_group_ids = [aws_security_group.vps.id]

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  # user_data is limited to 16 KB uncompressed but cloud-init accepts gzip.
  # We exceed 16 KB because of the embedded bot.py + install-bot.sh, so we
  # gzip and base64-encode (user_data_base64 has a larger effective limit).
  user_data_base64 = base64gzip(templatefile("${path.module}/scripts/setup-xray.sh", {
    xray_uuid              = random_uuid.xray_uuid.result
    xray_short_id          = random_id.xray_short_id.hex
    camouflage_domain      = var.camouflage_domain
    mtproto_port           = var.mtproto_port
    mtproto_mask_domain    = var.mtproto_mask_domain
    telegram_bot_token     = var.telegram_bot_token
    telegram_allowed_users = jsonencode(var.telegram_allowed_users)
    aws_region             = var.aws_region
    bot_py                 = file("${path.module}/scripts/bot.py")
    install_bot_sh         = file("${path.module}/scripts/install-bot.sh")
    tailscale_auth_key     = var.tailscale_auth_key
    tailscale_hostname     = var.tailscale_hostname
    tailscale_tags         = join(",", var.tailscale_tags)
    amnezia_enabled        = var.amnezia_enabled ? "true" : ""
    amnezia_port           = var.amnezia_port
    amnezia_jc             = var.amnezia_jc
    amnezia_jmin           = var.amnezia_jmin
    amnezia_jmax           = var.amnezia_jmax
    amnezia_s1             = var.amnezia_s1
    amnezia_s2             = var.amnezia_s2
    cloudflare_enabled     = var.cloudflare_enabled ? "true" : ""
    cloudflare_domain      = var.cloudflare_domain
    cloudflare_ws_path     = local.cloudflare_ws_path_resolved
  }))

  # user_data runs only on first boot. Changing it would force a full instance
  # replacement (new IP, new Xray Reality key => every VLESS link breaks).
  # Use `make bot-install` / `make bot-update` to push bot changes to a running
  # VPS without touching Xray or Telemt.
  lifecycle {
    ignore_changes = [user_data, user_data_base64]
  }

  tags = {
    Name = "lazy-vps"
  }
}

# --- Elastic IP ---

resource "aws_eip" "vps" {
  instance = aws_instance.vps.id
  domain   = "vpc"

  tags = {
    Name = "lazy-vps"
  }
}
