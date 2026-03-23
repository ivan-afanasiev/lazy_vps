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

# --- Networking ---

resource "aws_security_group" "vps" {
  name        = "lazy-vps-sg"
  description = "Allow SSH and VLESS Reality (443)"

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_cidr_blocks
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

# --- EC2 Instance ---

resource "aws_instance" "vps" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.instance_type
  key_name      = aws_key_pair.ssh.key_name

  vpc_security_group_ids = [aws_security_group.vps.id]

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  user_data = templatefile("${path.module}/scripts/setup-xray.sh", {
    xray_uuid          = random_uuid.xray_uuid.result
    xray_short_id      = random_id.xray_short_id.hex
    camouflage_domain  = var.camouflage_domain
    mtproto_port       = var.mtproto_port
    mtproto_mask_domain = var.mtproto_mask_domain
  })

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
