# lazy-vps

Personal VPN + Telegram proxy on AWS, managed with Terraform.

- **VPN**: VLESS + XTLS-Reality (Xray-core) — looks like regular HTTPS to DPI
- **Telegram**: MTProto proxy (Telemt) — active-probe resistant, impersonates a real website
- **Telegram bot**: monitor and control everything from your phone

One command to deploy, one command to destroy. Runs on a single `t3.micro` — fits in the AWS free tier for new accounts.

---

## Table of contents

- [What you need](#what-you-need)
- [Quick start](#quick-start)
- [Connecting — VPN](#connecting--vpn)
- [Connecting — Telegram](#connecting--telegram)
- [Sharing with friends and family](#sharing-with-friends-and-family)
- [Telegram bot](#telegram-bot)
- [Configuration](#configuration)
- [How it works](#how-it-works)
- [Cost](#cost)
- [Troubleshooting](#troubleshooting)
- [Useful commands](#useful-commands)

---

## What you need

Before you start, have these ready:

1. **An AWS account.** New ones get 750 t3.micro hours/month free for 12 months — enough to run this 24/7 at $0.
2. **An IAM user with enough permissions.** See [AWS IAM setup](#aws-iam-setup) below — friends copying this repo will need to create one too.
3. **A Telegram bot token** from [@BotFather](https://t.me/BotFather). Takes 30 seconds, see [Bot setup](#bot-setup).
4. **Your Telegram user ID** from [@userinfobot](https://t.me/userinfobot).
5. **Local tools:**
   - macOS: `brew install awscli terraform direnv`
   - Linux: your distro's packages for `awscli`, `terraform`, `direnv` (optional), plus `make`, `ssh`, `openssl`.

### AWS IAM setup

Terraform needs to create EC2 instances, security groups, an Elastic IP, an IAM role for the bot, and an instance profile. The simplest path is to **create a dedicated IAM user with `AdministratorAccess`** and use that user's access keys only for `lazy-vps`. If you'd rather be minimal, the exact permissions needed are:

- `ec2:*` — EC2 instances, EIPs, security groups, key pairs
- `iam:GetRole`, `iam:CreateRole`, `iam:DeleteRole`, `iam:PutRolePolicy`, `iam:DeleteRolePolicy`, `iam:GetRolePolicy`, `iam:CreateInstanceProfile`, `iam:DeleteInstanceProfile`, `iam:AddRoleToInstanceProfile`, `iam:RemoveRoleFromInstanceProfile`, `iam:GetInstanceProfile`, `iam:PassRole`, `iam:TagRole`
- `cloudwatch:GetMetricStatistics` — used by the bot's `/traffic` command at runtime

Once the user exists, grab its access key ID + secret and run `aws configure` (or `make aws-configure`) to save them locally.

---

## Quick start

```bash
# 1. Clone and enter
git clone https://github.com/ivan-afanasiev/lazy_vps.git
cd lazy_vps

# 2. Verify tools are installed
make check

# 3. Configure AWS credentials
make aws-configure

# 4. Configure the Telegram bot (required — see "Bot setup" below)
cp .envrc.example .envrc
#   Edit .envrc: put your real bot token and Telegram user ID in it,
#   then either `direnv allow` or `source .envrc` for this shell.

# 5. Initialize Terraform
make setup

# 6. Deploy
make deploy            # ~2 min to provision, ~3-4 min more for cloud-init

# 7. After ~5 minutes, get your links
make vless-link        # VPN
make tg-link           # Telegram proxy

# 8. Message your Telegram bot `/start` to verify it responds
```

That's it. Import the VLESS link into a VPN client app (table below) and tap the `tg://proxy?...` link in Telegram to enable the MTProto proxy.

### Bot setup

The bot is **required** right now — `make deploy` will refuse without the two env vars below. To get a token:

1. Open Telegram, message [@BotFather](https://t.me/BotFather), send `/newbot`, follow the prompts, copy the `123456:ABC…` token.
2. Message [@userinfobot](https://t.me/userinfobot) and copy your numeric user ID.
3. Put both in `.envrc`:

```bash
export TF_VAR_telegram_bot_token='123456:ABCDEF_your_real_token'
export TF_VAR_telegram_allowed_users='["123456789"]'
```

The `TF_VAR_telegram_allowed_users` is a JSON array. You can mix numeric IDs and `@usernames` (without the `@`). IDs never change; usernames can, so IDs are preferred.

```bash
# Example with a family member
export TF_VAR_telegram_allowed_users='["123456789","mom_username"]'
```

`.envrc` is gitignored — safe to keep secrets in it. With `direnv` installed, it loads automatically when you `cd` into the repo.

---

## Connecting — VPN

Run `make vless-link` (or message the bot `/vless`) to get a `vless://…` link. Import it into a client:

| Platform | App | Where to get it |
|----------|-----|-----------------|
| iOS | Streisand | [App Store](https://apps.apple.com/app/streisand/id6450534064) |
| iOS | V2Box | [App Store](https://apps.apple.com/app/v2box-v2ray-client/id6446814690) |
| macOS | V2Box | [App Store](https://apps.apple.com/app/v2box-v2ray-client/id6446814690) |
| macOS | Hiddify Next | [GitHub](https://github.com/hiddify/hiddify-next/releases) |
| Android | v2rayNG | [Play Store](https://play.google.com/store/apps/details?id=com.v2ray.ang) |
| Android | Hiddify Next | [GitHub](https://github.com/hiddify/hiddify-next/releases) |
| Windows | v2rayN | [GitHub](https://github.com/2dust/v2rayN/releases) |

Most apps accept "paste from clipboard" or "scan QR" — either works. In v2rayNG specifically: tap the `+` → "Import config from clipboard".

---

## Connecting — Telegram

Run `make tg-link` (or message the bot `/tg`) to get a `tg://proxy?…` link. **Just tap the link on any device that has Telegram installed** — the app will pop up a dialog offering to enable the proxy. No extra apps.

> Note: the Telegram proxy and a third-party VPN on the same device usually fight each other. See [Troubleshooting → Telegram proxy doesn't work when VPN is on](#telegram-proxy-doesnt-work-when-a-vpn-is-on).

---

## Sharing with friends and family

Two distinct roles:

- **Operator** (you) — runs `make deploy`, pays the AWS bill, manages the bot.
- **User** (friend) — just uses the link you send them. No AWS account, no Terraform, no bot access (unless you add them to `TF_VAR_telegram_allowed_users`).

For each new friend:

```bash
# Share the VPN link via a secure channel (Signal, iMessage, Telegram Secret Chat).
# The link IS the credential — anyone with it can use your VPN.
make vless-link

# Telegram proxy link — same deal
make tg-link
```

One link currently equals one shared credential. If you want **per-user credentials with usage tracking and revocation** (so you can see who's consuming 200 GB and kick them), that's a future feature — not implemented yet.

### Monitoring usage

```bash
make users           # Top client IPs per service this month
make destinations    # Top destinations your VPN users connect to
make traffic         # Instance-level network bytes (CloudWatch)
```

All three are also available in the bot as `/users`, `/destinations`, `/traffic`.

### Giving a friend bot access

Add their Telegram username (or numeric ID) to `TF_VAR_telegram_allowed_users` and run `make bot-install`. No redeploy needed:

```bash
export TF_VAR_telegram_allowed_users='["123456789","alice","bob"]'
make bot-install
```

Everyone in the list has full bot access (including `/restart`). Don't add people you don't trust with that.

---

## Telegram bot

The VPS runs a small Python bot (`lazy-vps-bot`) in a Docker container alongside xray and telemt. It exposes read-only monitoring commands plus the ability to restart services.

### Commands

- `/vless` — VLESS connection link
- `/tg` — Telegram proxy link
- `/status` — Xray service status
- `/tgstatus` — Telemt container status + last logs
- `/traffic` — month-to-date network traffic from CloudWatch
- `/destinations [N]` — top N destinations this month (default 20, `0` = all)
- `/users [N]` — top N client IPs per service this month (default 10, `0` = all)
- `/restart xray|telemt` — restart a service
- `/help` — list commands

Only users listed in `TF_VAR_telegram_allowed_users` can invoke commands; everyone else gets `Not authorized.` and the attempt is logged (`make bot-logs`).

### Adding the bot to an already-deployed VPS

If you deployed an older version of this repo before the bot existed, you can install the bot in-place — no reboot, no new IP, existing VLESS/Telegram users keep working:

```bash
git pull
# Make sure TF_VAR_telegram_bot_token and TF_VAR_telegram_allowed_users are set
make deploy          # Applies the IAM role + instance profile. user_data
                     # changes are ignored on existing instances (lifecycle
                     # ignore_changes rule), so the VPS is NOT replaced.
make bot-install     # Installs the bot on the running VPS. Idempotent.
```

### Updating the bot later

- **Code-only change** (you edited `terraform/scripts/bot.py`): `make bot-update` — re-syncs `bot.py` and rebuilds the container, keeps `bot.env` as-is.
- **Change allowed users or token**: edit `.envrc`, then `make bot-install` — it re-renders `bot.env` and restarts the container.

---

## Configuration

All defaults live in `terraform/variables.tf`. Override them by creating `terraform/terraform.tfvars`:

```hcl
aws_region          = "eu-central-1"
instance_type       = "t3.micro"
ssh_public_key_path = "~/.ssh/id_ed25519.pub"
camouflage_domain   = "www.vk.com"
ssh_cidr_blocks     = ["0.0.0.0/0"]
mtproto_port        = 8443
mtproto_mask_domain = "www.yandex.ru"
```

### Camouflage domains

**VLESS Reality** (`camouflage_domain`) — the domain your VPN pretends to be during a Reality handshake. Pick a popular site with TLS 1.3 that's **reachable from wherever your users connect from** and **not itself blocked**. Defaults to `www.vk.com`. Other options that tend to work well for users in Russia: `www.yandex.ru`, `mail.ru`, `ok.ru`.

**Telegram MTProto** (`mtproto_mask_domain`) — the domain telemt impersonates when an active prober pokes port 8443. Same selection criteria. Default `www.yandex.ru`.

These domains are the **cover story** your traffic presents to anyone inspecting the line; they don't change where you actually connect. You can change them anytime with `make deploy` — existing connections drop and reconnect.

### AWS region

You pick this in `terraform.tfvars`. The closer to your users, the lower the latency. For users in Russia/CIS, `eu-central-1` (Frankfurt) or `eu-north-1` (Stockholm) are best. For users in Western Europe, `eu-west-1` (Ireland).

---

## How it works

```
                    ┌──────────────────────────────────┐
                    │  EC2 t3.micro (Ubuntu 24.04)     │
  VPN traffic ─────▶│  Xray (port 443)                 │──▶ Internet
  (all apps)        │  VLESS + XTLS-Reality            │
                    │  Looks like HTTPS to vk.com      │
                    │                                  │
  Telegram ────────▶│  Telemt (port 8443)              │──▶ Telegram servers
  (proxy in app)    │  MTProto + fake TLS (yandex.ru)  │
                    │                                  │
  You (Telegram) ──▶│  lazy-vps-bot (Python, Docker)   │
                    │  IAM role → CloudWatch API       │
                    └──────────────────────────────────┘
```

Xray and telemt are independent — they share only the VPS. You can use either, both, or neither on a given device.

---

## Cost

Expect **$0 to ~$3/month** for personal use:

- **t3.micro**: free tier, 750 hrs/month for 12 months on new accounts. After that, ~$7.50/month.
- **Elastic IP**: free while attached to a running instance, $3.65/month if the instance is stopped.
- **Data transfer out**: 100 GB/month free across the whole account, then $0.09/GB up to 10 TB.
- **EBS (disk)**: 8 GB gp3 ≈ $0.66/month (mostly eaten by free tier).

`make traffic` or `/traffic` shows your month-to-date egress and rough billable amount.

---

## Troubleshooting

### `make deploy` fails with `iam:CreateRole` AccessDenied

Your IAM user doesn't have the permissions to create the bot's IAM role. See [AWS IAM setup](#aws-iam-setup). Easiest fix: grant the user `AdministratorAccess` (or ask your account admin to).

### SSH: "REMOTE HOST IDENTIFICATION HAS CHANGED!"

You previously deployed `lazy-vps`, destroyed it, and deployed again — the new VPS has a different host key at the same IP. Remove the stale entry:

```bash
IP=$(cd terraform && terraform output -raw server_ip)
ssh-keygen -R "$IP"
ssh -o StrictHostKeyChecking=accept-new ubuntu@$IP 'echo ok'
```

### `make bot-install` fails with `Could not get lock /var/lib/dpkg/lock-frontend`

Cloud-init is still running (`apt-get upgrade`) on a freshly deployed VPS. Wait for it to finish and retry:

```bash
IP=$(cd terraform && terraform output -raw server_ip)
ssh ubuntu@$IP 'cloud-init status --wait'
make bot-install
```

(The installer script itself now waits for this automatically; this only bites older deployments.)

### Bot says "Xray public key not available yet" or the VPN won't connect

This happens if Xray's `x25519` output format changed and the setup script's parser didn't match. Fresh deploys shouldn't hit it (the parser handles the three known output formats), but if an older deployment has an empty `public_key.txt`, the cleanest fix is `make destroy && make deploy` and redistribute fresh links. If you need to repair in place without rotating keys, SSH in and re-derive from the private key already in `config.json`:

```bash
make ssh
sudo -s
PRIV=$(grep -oE '"privateKey":"[^"]+"' /usr/local/etc/xray/config.json | cut -d'"' -f4)
/usr/local/bin/xray x25519 -i "$PRIV" \
  | awk -F': *' '/^(Password|PublicKey|Public key)/{print $2; exit}' \
  > /usr/local/etc/xray/public_key.txt
chmod 644 /usr/local/etc/xray/public_key.txt
cat /usr/local/etc/xray/public_key.txt
```

### Telegram proxy doesn't work when a VPN is on

MTProto proxies and general-purpose VPNs on the same device typically collide, for three reasons:

1. **Commercial VPNs often block MTProto** traffic on purpose (to discourage Telegram-over-VPN abuse).
2. **Telegram's own app routes calls and push through the OS** rather than the configured proxy — inconsistent with VPN tunneling.
3. **Loop routing** if the "VPN" is also `lazy-vps` (your VLESS): Telegram → VLESS → VPS → back to the same VPS:8443 is a routing loop.

Pick one at a time. If you need both tunnels, use VLESS (which handles all traffic including Telegram) instead of stacking VPN+proxy.

### "Special user nobody configured, this is not safe!" in `make status`

Cosmetic systemd warning from Xray's upstream service unit. Harmless; Xray runs fine.

### `/users` or `/destinations` returns no data

Xray only writes access log entries when a real client successfully connects. A freshly deployed VPS has an empty log until someone actually uses the VPN. Connect once from a client app, load a webpage, and the data will appear. If it still doesn't — check `ssh ubuntu@$IP 'sudo wc -l /var/log/xray/access.log'`.

### Bot `/tgstatus` shows "Read-only file system" warnings

Cosmetic. Telemt tries to persist a runtime stats snapshot to `/etc/telemt/beobachten.txt` but the container is read-only. This is fixed in the default compose file (tmpfs mount on `/etc/telemt`); older deployments may still show it. Safe to ignore.

---

## Useful commands

```bash
# Deploy / destroy
make check              # Verify prereqs
make aws-configure      # Save AWS credentials
make setup              # terraform init
make deploy             # terraform apply
make destroy            # terraform destroy
make plan               # Preview changes

# Links
make vless-link         # VPN link
make tg-link            # Telegram proxy link

# Monitoring
make status             # Xray service status
make tg-status          # Telemt container status
make users [TOP=N]      # Top client IPs per service this month
make destinations [TOP=N]  # Top destinations this month
make traffic            # CloudWatch traffic + cost estimate

# Bot lifecycle
make bot-status         # Bot container status
make bot-logs           # Follow bot logs
make bot-restart        # Restart bot container
make bot-install        # Install/upgrade bot (re-renders bot.env)
make bot-update         # Fast: sync bot.py only and rebuild

# Misc
make ssh                # SSH into the VPS
make logs               # Follow xray logs
make setup-log          # View cloud-init log
make output             # Show Terraform outputs
make help               # Show all targets
```

---

## License

MIT
