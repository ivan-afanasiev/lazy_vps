# lazy-vps

Personal VPN + Telegram proxy server on AWS — DPI-resistant, disguises traffic as normal HTTPS.

- **VPN**: VLESS + XTLS-Reality (Xray-core) — looks like regular HTTPS to DPI
- **Telegram**: MTProto proxy (Telemt) — resists active probing, impersonates a real website

Managed with Terraform. One command to deploy, one command to destroy.

## Prerequisites

1. **AWS Account** with Access Key ID and Secret Access Key
2. **AWS CLI** — `brew install awscli` then `aws configure`
3. **Terraform** — `brew install terraform`
4. **SSH key** — default expects `~/.ssh/id_ed25519.pub` (override with `ssh_public_key_path` variable)

## Quick Start

```bash
# 1. Check prerequisites (installs nothing, just verifies)
make check

# 2. Configure AWS credentials (if check says they're missing)
make aws-configure

# 3. First-time setup: verify prereqs + terraform init
make setup

# 4. Deploy the VPS
make deploy

# 5. Wait ~3-4 minutes, then get your links
make vless-link    # VPN connection link
make tg-link       # Telegram proxy link

# 6. Import links into your apps (see below)
```

## Connecting — VPN

Copy the `vless://...` link and import it into your client:

| Platform | App | Import Method |
|----------|-----|---------------|
| iOS | [Streisand](https://apps.apple.com/app/streisand/id6450534064) | Paste link or scan QR |
| iOS | [V2Box](https://apps.apple.com/app/v2box-v2ray-client/id6446814690) | Paste link |
| macOS | [V2Box](https://apps.apple.com/app/v2box-v2ray-client/id6446814690) | Paste link |
| macOS | [Hiddify Next](https://github.com/hiddify/hiddify-next/releases) | Paste link |
| Android | [v2rayNG](https://play.google.com/store/apps/details?id=com.v2ray.ang) | Paste link or scan QR |
| Android | [Hiddify Next](https://github.com/hiddify/hiddify-next/releases) | Paste link |
| Windows | [v2rayN](https://github.com/2dust/v2rayN/releases) | Paste link |

## Connecting — Telegram

Run `make tg-link` to get a `tg://proxy?...` link. Open it on any device with Telegram installed — it will offer to enable the proxy. No extra apps needed.

You can share this link with friends/family. Each person just taps the link in Telegram and they're connected. They don't need VPN access or any special app.

## Useful Commands

```bash
make ssh          # SSH into the VPS
make status       # Check if Xray is running
make tg-status    # Check Telemt (Telegram proxy) status
make logs         # Stream Xray logs
make setup-log    # View cloud-init setup log
make output       # Show all Terraform outputs
make plan         # Preview changes without applying
make destroy      # Tear everything down
make help         # Show all available commands
```

## Configuration

Override defaults by creating `terraform.tfvars`:

```hcl
aws_region          = "eu-central-1"
instance_type       = "t3.micro"
ssh_public_key_path = "~/.ssh/id_ed25519.pub"
camouflage_domain   = "www.vk.com"
ssh_cidr_blocks     = ["0.0.0.0/0"]
mtproto_port        = 8443
mtproto_mask_domain = "www.yandex.ru"
```

### Camouflage Domains

**VLESS Reality** (`camouflage_domain`) — the domain your VPN pretends to be. Good choices:
- `www.vk.com` (default)
- `www.yandex.ru`
- `mail.ru`
- `ok.ru`

**Telegram MTProto** (`mtproto_mask_domain`) — the domain Telemt impersonates during active probing. Good choices:
- `www.yandex.ru` (default)
- `www.vk.com`
- `mail.ru`
- `dzen.ru`

Pick popular domestic Russian sites with TLS 1.3 support. These will never be blocked by Roskomnadzor.

## How It Works

```
                    ┌──────────────────────────────────┐
                    │  EC2 t3.micro (Ubuntu 24.04)     │
                    │                                  │
  VPN traffic ─────▶│  Xray (port 443)                 │──▶ Internet
  (all apps)        │  VLESS + XTLS-Reality            │
                    │  Looks like HTTPS to vk.com     │
                    │                                  │
  Telegram ────────▶│  Telemt (port 8443)              │──▶ Telegram servers
  (direct in app)   │  MTProto + Fake TLS              │
                    │  Active probes see yandex.ru    │
                    └──────────────────────────────────┘
```

## Cost

- **t3.micro**: Free tier eligible (750 hrs/month for 6 months on new accounts)
- **Elastic IP**: Free while attached to a running instance
- **Data transfer**: 100 GB/month free, then ~$0.09/GB

## License

MIT
