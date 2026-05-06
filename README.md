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
- [Tailscale (optional)](#tailscale-optional)
- [Amnezia VPN (optional)](#amnezia-vpn-optional)
- [Cloudflare-fronted VLESS (optional)](#cloudflare-fronted-vless-optional)
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
aws_region          = "eu-north-1"
instance_type       = "t3.micro"
ssh_public_key_path = "~/.ssh/id_ed25519.pub"
camouflage_domain   = "dzen.ru"
ssh_cidr_blocks     = ["0.0.0.0/0"]
mtproto_port        = 8443
mtproto_mask_domain = "www.yandex.ru"
```

### Camouflage domains

**VLESS Reality** (`camouflage_domain`) — the domain your VPN pretends to be during a Reality handshake. Pick a popular site with TLS 1.3 that's **reachable from wherever your users connect from** and **not itself blocked**, *and* has a realistic ClientHello. Default is `dzen.ru` — a large RU-domestic site that's always reachable from inside Russia (where most users of this project actually are) and has a typical TLS handshake.

Other good 2026 picks:

- In-RU domestic (good if your users are there): `www.kinopoisk.ru`, `lenta.ru`.
- CDN-backed, globally reachable (use if your users connect from outside RU): `www.microsoft.com`, `www.bing.com`, `www.apple.com`, `swcdn.apple.com`.

Avoid `www.vk.com` — its TLS handshake is atypical, which actually *hurts* Reality's mimicry. See `docs/russia-whitelist-era.md` for context.

**Telegram MTProto** (`mtproto_mask_domain`) — the domain telemt impersonates when an active prober pokes port 8443. Same selection criteria. Default `www.yandex.ru`.

These domains are the **cover story** your traffic presents to anyone inspecting the line; they don't change where you actually connect. You can change them anytime with `make deploy` — existing connections drop and reconnect.

### AWS region

You can override this in `terraform.tfvars`. The default is `eu-north-1` (Stockholm) — currently the most reliable AWS region for users in Russia/CIS in 2026 (lighter TSPU throttling than Frankfurt). The closer to your users, the lower the latency. Other reasonable picks for RU/CIS:

- **`me-central-1` (UAE)** — different IP reputation, geographically reasonable.
- `eu-central-1` (Frankfurt) — lowest latency, but its AWS IP ranges have been heavily throttled on TSPU since 2024-2025. Avoid unless you've confirmed it works for your users.

For users in Western Europe, set `aws_region = "eu-west-1"` (Ireland). See `docs/russia-whitelist-era.md` for the full reasoning.

> **Changing region on an existing deployment** destroys the EC2 + EIP and recreates them — you get a new public IP and fresh Reality keys, so every VLESS / AmneziaWG link breaks. If you have a deployment running and don't want to rotate, pin the old region explicitly in `terraform/terraform.tfvars` *before* the next `make deploy`.

---

## Tailscale (optional)

For personal use you can join the VPS to your [Tailscale](https://tailscale.com) tailnet so that:

- **Public SSH (port 22) closes** — Terraform drops the rule entirely. Your VPS's only public-facing ports become 443 (VLESS) and 8443 (MTProto), which are already designed to survive the open internet.
- **You SSH over the tailnet** — `make ssh`, `make logs`, `make bot-install` and friends automatically use the tailnet hostname instead of the Elastic IP.
- **Tailscale SSH** is enabled on the VPS — no more managing `~/.ssh/authorized_keys`; auth happens via your Tailscale identity.

Your friends and family using the VPN/Telegram proxy are **unaffected** — they connect via the public Elastic IP as before. Only operator access (you, managing the box) moves to Tailscale.

> Not a replacement for VLESS. Tailscale is not a censorship-evasion tool; it doesn't disguise itself as HTTPS. Keep using VLESS/MTProto for that.

### Setup

1. Create a Tailscale account (the free Personal plan covers up to 100 devices).
2. Install Tailscale on the devices you want to manage the VPS from (Mac, iPhone, iPad).
3. Generate an auth key at [login.tailscale.com/admin/settings/keys](https://login.tailscale.com/admin/settings/keys). Recommended settings:
   - **Reusable**: off
   - **Ephemeral**: off (the VPS is long-lived)
   - **Pre-approved**: on (otherwise you have to manually approve the node after first boot)
   - **Expiry**: 90 days is fine; the machine stays online after the key expires
   - **Tags**: `tag:lazy-vps` (declare the tag in your tailnet's [ACL policy](https://login.tailscale.com/admin/acls) first, or skip tags entirely)
4. Add the key to `.envrc`:

   ```bash
   export TF_VAR_tailscale_auth_key='tskey-auth-XXXXXXXXXXX-XXXXXXXXXXXX'
   # Optional — defaults are fine:
   # export TF_VAR_tailscale_hostname='lazy-vps'
   # export TF_VAR_tailscale_tags='["tag:lazy-vps"]'
   ```

5. **For a fresh deployment**: `make deploy` — cloud-init installs Tailscale and joins the tailnet as the VPS comes up. Port 22 is never opened.

6. **For an existing deployment**: `make deploy` drops the SSH rule and applies Terraform changes, but cloud-init only runs on first boot, so Tailscale won't get installed on an already-running VPS. Two options:

   - **Easiest**: `make destroy && make deploy`. You'll get a new Elastic IP and fresh Reality keys, so every VLESS link needs to be redistributed. Fine if you're the only user.
   - **In-place**: SSH in (while port 22 is still open), run the installer manually, *then* `make deploy` to close port 22:

     ```bash
     make ssh
     curl -fsSL https://tailscale.com/install.sh | sudo sh
     sudo tailscale up --authkey="$TF_VAR_tailscale_auth_key" \
                      --hostname=lazy-vps --ssh \
                      --accept-dns=false --accept-routes=false
     exit
     make deploy   # now drops the public SSH rule
     ```

### Verifying

```bash
tailscale status                  # lists your devices; lazy-vps should appear
make ssh                          # should connect via the tailnet hostname
cd terraform && terraform output tailscale_enabled   # should print "true"
```

If `make ssh` hangs, make sure your laptop is on the tailnet (`tailscale status`) and that `lazy-vps` resolves (`tailscale ping lazy-vps`).

### Disabling Tailscale

Unset `TF_VAR_tailscale_auth_key` (or set it to an empty string) and `make deploy`. Terraform re-opens port 22 in the security group. The Tailscale daemon stays installed on the VPS; to remove the machine from your tailnet, run `sudo tailscale logout` on the VPS or delete it in the [admin console](https://login.tailscale.com/admin/machines).

### Why `--accept-dns=false`?

Xray resolves the Reality camouflage domain (`dzen.ru` by default) to sustain its cover story. Tailscale's MagicDNS, if enabled on the VPS itself, replaces `/etc/resolv.conf` and can interfere with that resolution under some setups. We disable MagicDNS on the VPS only — your *client* devices still resolve `lazy-vps` and other tailnet hostnames normally.

---

## Amnezia VPN (optional)

For users on networks where direct VLESS Reality is throttled (some Russian mobile operators in 2026, some captive Wi-Fi setups), you can enable a second tunnel: **AmneziaWG**.

AmneziaWG is the [Amnezia VPN](https://amnezia.org) project's obfuscated fork of WireGuard. Same crypto and performance as WireGuard, but the wire format is randomised (junk packets at handshake, header padding) so DPI can't fingerprint it as WG. It's UDP, so it provides a different transport profile than Reality (which is TCP/443) — when one path is degraded, the other often still works.

> Not a replacement for VLESS Reality. Reality is still the recommended primary transport: it survives stricter DPI and has better cover (looks like HTTPS to a real CDN). AmneziaWG is a *fallback* when UDP is fine on your network but TCP/443 to AWS is being throttled.

### Setup

1. Add the feature flag to `.envrc`:

   ```bash
   export TF_VAR_amnezia_enabled=true
   # Optional — defaults are fine:
   # export TF_VAR_amnezia_port=51820
   ```

2. **For a fresh deployment**: `make deploy` — cloud-init installs AmneziaWG via the official PPA, generates a server keypair plus one client keypair, and brings the interface up on UDP/51820. The security group opens UDP/51820 to the world.

3. **For an existing deployment**: cloud-init only runs on first boot, so flipping the flag on a live VPS won't install AmneziaWG. You have two options:

   - **Easiest**: `make destroy && make deploy`. New EIP, new Reality keys, every VLESS link needs to be redistributed. Fine if you're the only user.
   - **In-place**: SSH in and run the install steps from `terraform/scripts/setup-xray.sh` (the block under "AmneziaWG (optional)") manually. You'll still need `make deploy` after to open UDP/51820 in the security group.

### Connecting

```bash
make amnezia-link    # prints vpn:// link + saves amnezia-client.{vpn,conf}
make amnezia-qr      # downloads QR code to ./amnezia-client.png
```

`make amnezia-link` prints a `vpn://...` string and saves two files:

- `amnezia-client.vpn` — paste / send to anyone using the **Amnezia VPN** main app for one-tap import. Identical to what the app's "Share" button produces.
- `amnezia-client.conf` — standard AmneziaWG `.conf` for **AmneziaWG-only** clients (or any WireGuard app that understands AWG params).

Import into:

| Platform | App | Where to get it | Use this file |
|----------|-----|-----------------|---------------|
| iOS | Amnezia VPN | [App Store](https://apps.apple.com/app/amnezia-vpn/id1600529900) | `.vpn` (paste link / scan QR) |
| iOS | AmneziaWG | [App Store](https://apps.apple.com/app/amneziawg/id6478942365) | `.conf` |
| Android | Amnezia VPN | [Play Store](https://play.google.com/store/apps/details?id=org.amnezia.vpn) | `.vpn` |
| macOS / Windows / Linux | Amnezia VPN | [amnezia.org/downloads](https://amnezia.org/downloads) | `.vpn` |

**One-tap on phones**: `make amnezia-qr` → scan the resulting `amnezia-client.png` from the Amnezia VPN app.

> **One config = one credential** for now, same as VLESS. If you want to give a friend their own keypair, generate it on the VPS with `awg genkey | sudo tee /etc/amnezia/amneziawg/$NAME.privkey` and add a `[Peer]` block to `/etc/amnezia/amneziawg/awg0.conf`. Per-user credential management isn't built into the bot yet.

### Verifying

```bash
make amnezia-status   # shows interface state, last handshake, transferred bytes
```

If the interface is up but no handshake registered, the client hasn't connected yet — that's expected on a fresh deploy.

### Disabling AmneziaWG

Set `TF_VAR_amnezia_enabled=false` (or unset) and `make deploy`. Terraform removes UDP/51820 from the security group. The AmneziaWG service stays installed on the VPS; to stop it, `ssh ubuntu@<host> 'sudo systemctl disable --now awg-quick@awg0'`.

### Why is this off by default?

- AmneziaWG's optional upside doesn't matter for users in countries that don't actively block WireGuard.
- Opening UDP/51820 expands the public attack surface of the box (one more listening service).
- It costs ~5 MB of RAM and a DKMS module rebuild on every kernel upgrade.
- Reality alone fits the "single-button VPN that survives RU DPI" story for most users; the doc at `docs/russia-whitelist-era.md` covers when you'd actually need a second transport.

---

## Cloudflare-fronted VLESS (optional)

The reliability fallback for when direct VLESS Reality to AWS is being throttled. Adds a **second `vless://` link** that routes through Cloudflare instead of connecting directly to your VPS — so what TSPU (or any DPI) sees is a TLS connection to a Cloudflare anycast IP, not to your AWS Elastic IP.

How it works:

1. Client opens a TLS connection to `connect.lazy-vps.com:443` → resolves to a Cloudflare edge IP.
2. Cloudflare terminates TLS, sees a WebSocket upgrade for path `/<random>`, proxies the WS frames to your VPS.
3. The VPS's security group accepts those frames on `:8080` *only* from Cloudflare's published IPv4 ranges.
4. Xray reads the WS frames as a VLESS inbound and routes the tunneled traffic out.

Blocking this requires blocking Cloudflare itself in Russia — which would take out a huge chunk of the Russian internet. It's been threatened, never sustained.

> Reality is still the recommended primary transport (lower latency, no third party in the path). Cloudflare-WS is the *fallback* — distribute both links and most clients will pick the working one automatically.

### One-time setup (the part you do in the Cloudflare dashboard)

You need a domain you own (Cloudflare Free plan is enough). Skip steps 1-2 if your nameservers already point at Cloudflare.

1. **Add the domain to Cloudflare**: dash.cloudflare.com → Add a Site → enter your apex domain → Free plan. Cloudflare gives you two `*.ns.cloudflare.com` nameservers.
2. **Update nameservers at your registrar** (GoDaddy / Namecheap / etc.) to point at the Cloudflare ones. Wait for propagation (`dig NS yourdomain.com` should show the Cloudflare names — usually 10 min to 2 hours).
3. **DNS record** for the subdomain: Cloudflare → DNS → Records → Add record. Type `A`, Name `connect` (or whatever you want — this becomes `connect.yourdomain.com`), IPv4 = your VPS's Elastic IP, **Proxy status = 🟠 Proxied** (this is the whole point — orange cloud must be ON). TTL Auto.
4. **SSL/TLS mode**: Cloudflare → SSL/TLS → Overview → set to **"Full"** (NOT "Full (strict)" — Xray's WS endpoint serves plain HTTP to the Cloudflare side; CF terminates TLS upstream). Edge Certificates → ensure **"Always Use HTTPS"** is **off** (it interferes with WS upgrades on some configs).
5. **Origin Rule** to forward Cloudflare → your VPS on port 8080 (instead of the default 443): Cloudflare → Rules → Origin Rules → Create rule. Match: `Hostname` `equals` `connect.yourdomain.com`. Action: `Rewrite to dynamic` → **Origin port** = `8080`. Save.

### Setup (the Terraform side)

1. Add the feature flag and your domain to `.envrc`:

   ```bash
   export TF_VAR_cloudflare_enabled=true
   export TF_VAR_cloudflare_domain='connect.yourdomain.com'
   # Optional — leave unset and Terraform generates a random WS path:
   # export TF_VAR_cloudflare_ws_path='/some-secret-path'
   ```

2. **Fresh deployment**: `make deploy` — opens TCP/8080 in the SG (restricted to Cloudflare IP ranges, refreshed at every plan from `https://www.cloudflare.com/ips-v4`), and Xray is configured with the second VLESS-WS inbound.

3. **Existing deployment**: same caveat as Tailscale and AmneziaWG — `user_data` is `ignore_changes`'d, so the SG rule lands on the existing VPS but the new Xray inbound does not. Either `make destroy && make deploy` (rotates Reality keys), or SSH in and edit `/usr/local/etc/xray/config.json` by hand to add the WS inbound.

### Connecting

```bash
make vless-link
```

When `cloudflare_enabled` is on, this prints **two** links: the existing Reality one *and* a new `lazy-vps-cf` one. Distribute both. Most clients (Hiddify Next, v2rayN, V2Box) accept multiple configs and try them in order; if Reality is degraded, the CF-WS one takes over.

### Verifying it actually goes through Cloudflare

```bash
# DNS resolves to Cloudflare's edge:
dig +short connect.yourdomain.com
# Should be 104.x or 172.x or 188.x — Cloudflare ranges, not your EIP.

# Cloudflare answers TLS with the right cert:
echo | openssl s_client -connect connect.yourdomain.com:443 -servername connect.yourdomain.com 2>/dev/null \
  | openssl x509 -noout -ext subjectAltName
# Should show "*.yourdomain.com" — Cloudflare's Universal SSL cert.

# The WS endpoint is alive (will 404 from Xray on a wrong path; that's correct):
curl -I https://connect.yourdomain.com/wrong-path
# HTTP/2 404 from Cloudflare or your origin = healthy.
```

### Disabling

Set `TF_VAR_cloudflare_enabled=false` (or unset) and `make deploy`. Terraform removes the SG rule. The Xray WS inbound stays in `config.json` on the running VPS until the next instance replacement; harmless because Cloudflare can no longer reach it. You can also remove the DNS record from Cloudflare (or just disable the orange cloud) to clean up the domain side.

### Why this is off by default

- It only matters if you've actually seen direct Reality get throttled — extra latency for nothing if Reality is working fine on your network.
- Requires a domain (yearly registration cost) and a Cloudflare account.
- Trades the "100% control of the path" property of Reality for "Cloudflare sees the connection metadata". Cloudflare can't decrypt your VPN traffic (VLESS encrypts inside the WS), but it sees source/dest IPs, timing, and traffic volumes per their ToS.
- Adds ~30-100 ms of latency vs. direct Reality.

> Per-user link rotation is not built in. Right now the same VLESS UUID is used for both Reality and the CF-WS link, so you can't revoke just one. If a CF-WS link leaks, rotating it means rotating the Reality one too (`make destroy && make deploy`).

---

## How it works

```
                    ┌──────────────────────────────────┐
                    │  EC2 t3.micro (Ubuntu 24.04)     │
  VPN traffic ─────▶│  Xray (port 443/tcp)             │──▶ Internet
  (all apps)        │  VLESS + XTLS-Reality            │
                    │  Looks like HTTPS to dzen.ru     │
                    │                                  │
  Telegram ────────▶│  Telemt (port 8443)              │──▶ Telegram servers
  (proxy in app)    │  MTProto + fake TLS (yandex.ru)  │
                    │                                  │
  VPN traffic ─────▶│  AmneziaWG (port 51820/udp)      │──▶ Internet
  (optional flag)   │  Obfuscated WireGuard            │
                    │                                  │
  VPN traffic ─────▶│  Xray VLESS-WS (port 8080/tcp)   │──▶ Internet
  via Cloudflare    │  Reached only via Cloudflare;    │
  (optional flag)   │  CF terminates TLS upstream      │
                    │                                  │
  You (Telegram) ──▶│  lazy-vps-bot (Python, Docker)   │
                    │  IAM role → CloudWatch API       │
                    └──────────────────────────────────┘
```

Xray, telemt, and AmneziaWG are independent — they share only the VPS. You can use any combination on a given device. AmneziaWG and Cloudflare-fronted VLESS are off by default; see [Amnezia VPN (optional)](#amnezia-vpn-optional) and [Cloudflare-fronted VLESS (optional)](#cloudflare-fronted-vless-optional).

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
make vless-link         # VPN link(s) — Reality + Cloudflare-WS if enabled
make tg-link            # Telegram proxy link
make amnezia-link       # AmneziaWG vpn:// link + .conf (only if amnezia_enabled=true)
make amnezia-qr         # Download AmneziaWG QR code as PNG

# Monitoring
make status             # Xray service status
make tg-status          # Telemt container status
make amnezia-status     # AmneziaWG interface status (peers, handshake, transfer)
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
