#!/bin/bash
set -euo pipefail
exec > /var/log/xray-setup.log 2>&1

export DEBIAN_FRONTEND=noninteractive

XRAY_UUID="${xray_uuid}"
XRAY_SHORT_ID="${xray_short_id}"
CAMOUFLAGE_DOMAIN="${camouflage_domain}"
MTPROTO_PORT="${mtproto_port}"
MTPROTO_MASK_DOMAIN="${mtproto_mask_domain}"
TELEGRAM_BOT_TOKEN="${telegram_bot_token}"
TELEGRAM_ALLOWED_USERS='${telegram_allowed_users}'
AWS_REGION="${aws_region}"
TAILSCALE_AUTH_KEY="${tailscale_auth_key}"
TAILSCALE_HOSTNAME="${tailscale_hostname}"
TAILSCALE_TAGS="${tailscale_tags}"
AMNEZIA_ENABLED="${amnezia_enabled}"
AMNEZIA_PORT="${amnezia_port}"
AMNEZIA_JC="${amnezia_jc}"
AMNEZIA_JMIN="${amnezia_jmin}"
AMNEZIA_JMAX="${amnezia_jmax}"
AMNEZIA_S1="${amnezia_s1}"
AMNEZIA_S2="${amnezia_s2}"
CLOUDFLARE_ENABLED="${cloudflare_enabled}"
CLOUDFLARE_DOMAIN="${cloudflare_domain}"
CLOUDFLARE_WS_PATH="${cloudflare_ws_path}"

# --- System Update ---
apt-get update -y
apt-get upgrade -y

# --- Enable BBR (TCP congestion control for better throughput) ---
cat >> /etc/sysctl.conf <<SYSCTL
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.ip_forward = 1
SYSCTL
sysctl -p

# --- Install Xray ---
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

# --- Generate x25519 keypair ---
KEY_OUTPUT=$(/usr/local/bin/xray x25519)
PRIVATE_KEY=$(echo "$KEY_OUTPUT" | awk -F': *' '/^(PrivateKey|Private key)/{print $2; exit}')
PUBLIC_KEY=$(echo "$KEY_OUTPUT"  | awk -F': *' '/^(Password|PublicKey|Public key)/{print $2; exit}')
if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
  echo "FATAL: could not parse xray x25519 output:" >&2
  echo "$KEY_OUTPUT" >&2
  exit 1
fi

# --- Build optional Cloudflare-fronted VLESS-WS inbound ---
# When enabled, Xray also listens on the loopback-reachable port 8080
# in plain HTTP, expecting WebSocket upgrades on $CLOUDFLARE_WS_PATH.
# Cloudflare's edge terminates TLS for $CLOUDFLARE_DOMAIN and proxies
# the upgraded WS frames to us — so on the wire from the VPS's POV
# this is HTTP, but to clients (and to TSPU) it's all wrapped in
# Cloudflare's edge TLS.
if [ -n "$CLOUDFLARE_ENABLED" ]; then
  CF_INBOUND_JSON=$(cat <<CFINBOUND
,
    {
      "listen": "0.0.0.0",
      "port": 8080,
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "$XRAY_UUID" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "security": "none",
        "wsSettings": {
          "path": "$CLOUDFLARE_WS_PATH",
          "headers": {
            "Host": "$CLOUDFLARE_DOMAIN"
          }
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }
CFINBOUND
)
else
  CF_INBOUND_JSON=""
fi

# --- Write Xray Config ---
cat > /usr/local/etc/xray/config.json <<XRAYCONF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$XRAY_UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$CAMOUFLAGE_DOMAIN:443",
          "xver": 0,
          "serverNames": [
            "$CAMOUFLAGE_DOMAIN"
          ],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": [
            "$XRAY_SHORT_ID"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ]
      }
    }$CF_INBOUND_JSON
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
XRAYCONF

# --- Save public key for client config retrieval ---
echo "$PUBLIC_KEY" > /usr/local/etc/xray/public_key.txt
chmod 644 /usr/local/etc/xray/public_key.txt

# --- Save Cloudflare-WS metadata for client config retrieval ---
# `make vless-link` reads these to assemble the second link. Same UUID
# as Reality (see config.json above), only the transport differs.
if [ -n "$CLOUDFLARE_ENABLED" ]; then
  echo "$CLOUDFLARE_DOMAIN" > /usr/local/etc/xray/cf_domain.txt
  echo "$CLOUDFLARE_WS_PATH" > /usr/local/etc/xray/cf_ws_path.txt
  chmod 644 /usr/local/etc/xray/cf_domain.txt /usr/local/etc/xray/cf_ws_path.txt
fi

# --- Enable and Start ---
systemctl enable xray
systemctl restart xray

echo "=== Xray setup complete ==="
echo "UUID: $XRAY_UUID"
echo "Public Key: $PUBLIC_KEY"
echo "Short ID: $XRAY_SHORT_ID"
echo "SNI: $CAMOUFLAGE_DOMAIN"

# ============================================
# Telegram MTProto Proxy (Telemt)
# ============================================

# --- Install Docker ---
apt-get install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable docker
systemctl start docker

# --- Generate MTProto secret ---
MTPROTO_SECRET=$(openssl rand -hex 16)

# --- Create Telemt config ---
mkdir -p /opt/telemt
cat > /opt/telemt/telemt.toml <<TELEMT
show_link = ["user1"]

[general]
prefer_ipv6 = false
fast_mode = true
use_middle_proxy = false

[general.modes]
classic = false
secure = false
tls = true

[server]
port = $MTPROTO_PORT
listen_addr_ipv4 = "0.0.0.0"
listen_addr_ipv6 = "::"

[censorship]
tls_domain = "$MTPROTO_MASK_DOMAIN"
mask = true
mask_port = 443
fake_cert_len = 2048

[access.users]
user1 = "$MTPROTO_SECRET"

[[upstream]]
type = "direct"
enabled = true
weight = 10
TELEMT

# --- Create Docker Compose for Telemt ---
cat > /opt/telemt/docker-compose.yml <<COMPOSE
services:
  telemt:
    image: whn0thacked/telemt-docker:latest
    container_name: telemt
    restart: unless-stopped
    environment:
      RUST_LOG: "info"
    volumes:
      - ./telemt.toml:/etc/telemt.toml:ro
    ports:
      - "$MTPROTO_PORT:$MTPROTO_PORT/tcp"
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
    read_only: true
    tmpfs:
      - /tmp:rw,nosuid,nodev,noexec,size=16m
      # Telemt periodically flushes a runtime snapshot (beobachten.txt)
      # into /etc/telemt/. With read_only: true this produces a constant
      # stream of "Read-only file system" warnings in `docker logs`. We
      # don't rely on that state file (our /users parses docker logs),
      # so a tmpfs is enough to silence the warning.
      - /etc/telemt:rw,nosuid,nodev,noexec,size=8m
    deploy:
      resources:
        limits:
          cpus: "0.50"
          memory: 256M
COMPOSE

# --- Start Telemt ---
cd /opt/telemt
docker compose up -d

# Wait for Telemt to start and extract the tg:// link from logs
sleep 5
TG_LINK=$(docker compose logs 2>&1 | grep -oP 'tg://proxy\S+' | head -1 || true)

if [ -z "$TG_LINK" ]; then
  # Build the link manually if log parsing fails
  MTPROTO_SECRET_EE="ee$MTPROTO_SECRET$(echo -n "$MTPROTO_MASK_DOMAIN" | xxd -p)"
  IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
  PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4)
  TG_LINK="tg://proxy?server=$PUBLIC_IP&port=$MTPROTO_PORT&secret=$MTPROTO_SECRET_EE"
fi

echo "$TG_LINK" > /opt/telemt/tg_link.txt
echo "$MTPROTO_SECRET" > /opt/telemt/secret.txt
chmod 644 /opt/telemt/tg_link.txt /opt/telemt/secret.txt

echo ""
echo "=== Telemt MTProto proxy setup complete ==="
echo "Port: $MTPROTO_PORT"
echo "Secret: $MTPROTO_SECRET"
echo "Mask domain: $MTPROTO_MASK_DOMAIN"
echo "Telegram link: $TG_LINK"

# ============================================
# lazy-vps-bot + lazy-vps-ctl
# ============================================
# bot.py (~24 KB) and install-bot.sh (~8 KB) used to be inlined via
# Terraform template expansion, but that pushed user_data past AWS's
# hard 16 KB cap once we added Amnezia + Cloudflare. Instead we fetch
# them from the project's public GitHub repo at the *exact commit*
# this user_data was rendered from, so deploys are reproducible:
# updating these scripts upstream doesn't change behaviour on
# already-running boxes (which use ignore_changes on user_data
# anyway), and a fresh deploy from any old commit gets the right
# matched pair. The installer is the same code path used by
# `make bot-install` on an already-running VPS.

LAZY_VPS_REPO="${lazy_vps_repo}"
LAZY_VPS_REF="${lazy_vps_ref}"
RAW_BASE="https://raw.githubusercontent.com/$LAZY_VPS_REPO/$LAZY_VPS_REF/terraform/scripts"

mkdir -p /opt/lazy-vps-bot

# `--retry-all-errors` retries on connection refused, DNS hiccups,
# 5xx, etc. — fresh EC2s sometimes need 10-20 s of network warmup
# before egress is fully online.
fetch_to() {
  local url="$1" dest="$2"
  curl -fsSL --retry 6 --retry-delay 5 --retry-all-errors --max-time 60 \
    -o "$dest" "$url"
}

fetch_to "$RAW_BASE/bot.py"          /opt/lazy-vps-bot/bot.py
fetch_to "$RAW_BASE/install-bot.sh"  /opt/lazy-vps-bot/install-bot.sh
chmod 644 /opt/lazy-vps-bot/bot.py
chmod 755 /opt/lazy-vps-bot/install-bot.sh

TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN" \
TELEGRAM_ALLOWED_USERS="$TELEGRAM_ALLOWED_USERS" \
AWS_REGION="$AWS_REGION" \
XRAY_UUID="$XRAY_UUID" \
XRAY_SHORT_ID="$XRAY_SHORT_ID" \
CAMOUFLAGE_DOMAIN="$CAMOUFLAGE_DOMAIN" \
MTPROTO_PORT="$MTPROTO_PORT" \
AMNEZIA_ENABLED="$AMNEZIA_ENABLED" \
TAILSCALE_ENABLED="$([ -n "$TAILSCALE_AUTH_KEY" ] && echo true || true)" \
BOT_PY_PATH=/opt/lazy-vps-bot/bot.py \
LAZY_VPS_INSIDE_CLOUDINIT=1 \
/opt/lazy-vps-bot/install-bot.sh

# ============================================
# Tailscale (optional)
# ============================================
# When TAILSCALE_AUTH_KEY is set, join the tailnet so you can reach this VPS
# over MagicDNS (e.g. `ssh ubuntu@lazy-vps`) without exposing SSH to the
# public internet. Runs last so any failure here leaves VLESS/MTProto/bot
# already up and working.
#
# --accept-dns=false is important: Tailscale's MagicDNS would otherwise
# replace /etc/resolv.conf, which breaks Xray's resolution of the Reality
# camouflage domain (dzen.ru by default) on some setups. MagicDNS still
# works from client devices that want to reach THIS host by name; the
# flag only affects what the VPS itself uses as its resolver.

if [ -n "$TAILSCALE_AUTH_KEY" ]; then
  echo ""
  echo "=== Installing Tailscale ==="
  curl -fsSL https://tailscale.com/install.sh | sh

  TS_ARGS=(
    --authkey="$TAILSCALE_AUTH_KEY"
    --hostname="$TAILSCALE_HOSTNAME"
    --ssh
    --accept-dns=false
    --accept-routes=false
  )
  if [ -n "$TAILSCALE_TAGS" ]; then
    TS_ARGS+=(--advertise-tags="$TAILSCALE_TAGS")
  fi

  # `tailscale up` occasionally returns non-zero transiently on first boot
  # (e.g. control plane DNS not cached yet). Retry a few times before giving
  # up — we don't want to fail cloud-init just because Tailscale is slow.
  for attempt in 1 2 3; do
    if tailscale up "$${TS_ARGS[@]}"; then
      echo "Tailscale up on attempt $attempt"
      break
    fi
    echo "tailscale up failed (attempt $attempt), retrying in 10s…"
    sleep 10
  done

  tailscale status || true
  echo "=== Tailscale setup complete ==="
else
  echo ""
  echo "=== Tailscale: skipped (no auth key provided) ==="
fi

# ============================================
# AmneziaWG (optional)
# ============================================
# Obfuscated WireGuard fork from the Amnezia VPN project. Same crypto as
# WireGuard, but the wire format is randomised (Jc junk packets at
# handshake, S1/S2 header padding) so DPI can't fingerprint it as WG.
#
# We install via the official PPA on Ubuntu (provides both the kernel
# DKMS module and the awg / awg-quick userspace tools), then:
#   1. Generate a server keypair + a single "default client" keypair.
#   2. Write /etc/amnezia/amneziawg/awg0.conf with the obfuscation params
#      and a NAT/forwarding PostUp so client traffic egresses to the
#      internet via the VPS's public IP.
#   3. Bring up awg-quick@awg0 and enable it across reboots.
#   4. Write the client-side config + a vpn:// import URI to
#      /opt/amnezia/ so `make amnezia-link` can fetch them.
#
# Runs last on purpose: any failure in here leaves Reality / Telemt / bot
# already up, and cloud-init still reports success.

if [ -n "$AMNEZIA_ENABLED" ]; then
  echo ""
  echo "=== Installing AmneziaWG ==="

  # Soften the error trap: AmneziaWG depends on the Amnezia PPA + a DKMS
  # kernel module build that occasionally lags new Ubuntu kernel point
  # releases. We don't want a transient PPA hiccup to fail cloud-init —
  # VLESS / Telemt / the bot are already up by the time we get here.
  set +e
  amnezia_setup() {
    set -e

    # The Amnezia PPA needs software-properties-common + python3-launchpadlib
    # on a minimal Ubuntu cloud image to add a PPA non-interactively.
    apt-get install -y software-properties-common python3-launchpadlib gnupg2 \
                       "linux-headers-$(uname -r)" iptables qrencode

    add-apt-repository -y ppa:amnezia/ppa
    apt-get update -y
    # The metapackage `amneziawg` pulls in the kernel module (DKMS) plus the
    # awg / awg-quick userspace tools.
    apt-get install -y amneziawg

    # IP forwarding is already enabled in /etc/sysctl.conf above (alongside
    # BBR), so AmneziaWG can NAT client traffic without extra sysctls here.

    install -d -m 700 /etc/amnezia/amneziawg
    install -d -m 755 /opt/amnezia

    # --- Generate keypairs ---
    SERVER_PRIV=$(awg genkey)
    SERVER_PUB=$(printf '%s' "$SERVER_PRIV" | awg pubkey)
    CLIENT_PRIV=$(awg genkey)
    CLIENT_PUB=$(printf '%s' "$CLIENT_PRIV" | awg pubkey)
    PSK=$(awg genpsk)

    # --- Network detection (egress NIC for the NAT MASQUERADE rule) ---
    DEFAULT_IFACE=$(ip -o -4 route show to default | awk '{print $5; exit}')
    DEFAULT_IFACE="$${DEFAULT_IFACE:-ens5}"

    # --- Public IP for the client config Endpoint ---
    IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
    PUBLIC_IP=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4)

    # --- Server config ---
    # 10.13.13.0/24 was picked to avoid common collisions: many home routers
    # use 192.168.0/1.0/24, AWS VPCs use 172.31/172.16, and Tailscale uses
    # 100.64/10. 10.13.13/24 is reserved by tradition for personal WG setups
    # and unlikely to clash with anything the user is already on.
    cat > /etc/amnezia/amneziawg/awg0.conf <<AWGCONF
[Interface]
Address = 10.13.13.1/24
ListenPort = $AMNEZIA_PORT
PrivateKey = $SERVER_PRIV
Jc = $AMNEZIA_JC
Jmin = $AMNEZIA_JMIN
Jmax = $AMNEZIA_JMAX
S1 = $AMNEZIA_S1
S2 = $AMNEZIA_S2
H1 = 1
H2 = 2
H3 = 3
H4 = 4
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -A POSTROUTING -o $DEFAULT_IFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT; iptables -t nat -D POSTROUTING -o $DEFAULT_IFACE -j MASQUERADE

[Peer]
PublicKey = $CLIENT_PUB
PresharedKey = $PSK
AllowedIPs = 10.13.13.2/32
AWGCONF
    chmod 600 /etc/amnezia/amneziawg/awg0.conf

    # --- Client config (handed to the user verbatim) ---
    cat > /opt/amnezia/client.conf <<CLIENTCONF
[Interface]
PrivateKey = $CLIENT_PRIV
Address = 10.13.13.2/32
DNS = 1.1.1.1, 1.0.0.1
Jc = $AMNEZIA_JC
Jmin = $AMNEZIA_JMIN
Jmax = $AMNEZIA_JMAX
S1 = $AMNEZIA_S1
S2 = $AMNEZIA_S2
H1 = 1
H2 = 2
H3 = 3
H4 = 4

[Peer]
PublicKey = $SERVER_PUB
PresharedKey = $PSK
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = $PUBLIC_IP:$AMNEZIA_PORT
PersistentKeepalive = 25
CLIENTCONF
    chmod 644 /opt/amnezia/client.conf

    # --- vpn:// URI for one-tap import in the Amnezia VPN client app ---
    # The Amnezia client wants a custom envelope, not just base64 of the
    # WireGuard .conf:
    #
    #   vpn:// + base64url( <4-byte big-endian uncompressed JSON length>
    #                       + zlib(deflate)(JSON) )
    #
    # The JSON shape mirrors what the official AmneziaVPN app emits when
    # you "Share → AmneziaWG native format" (see ne0x/wg-easy
    # generateAmneziaVPNClientConfig + andr13/amnezia-config-decoder for
    # the canonical encode/decode). The .conf string lives inside
    # containers[0].awg.last_config (which is itself a *stringified* JSON
    # object — that double-encoding is intentional and required).
    #
    # We feed all the dynamic values in via env vars so the Python source
    # stays a literal heredoc and we don't have to fight Terraform
    # templating + bash quoting + Python string syntax simultaneously.
    AMN_PUBLIC_IP="$PUBLIC_IP" \
    AMN_PORT="$AMNEZIA_PORT" \
    AMN_CONF=/opt/amnezia/client.conf \
    AMN_OUT=/opt/amnezia/vpn.uri \
    AMN_CLIENT_PRIV="$CLIENT_PRIV" \
    AMN_CLIENT_IP="10.13.13.2/32" \
    AMN_SERVER_PUB="$SERVER_PUB" \
    AMN_PSK="$PSK" \
    AMN_JC="$AMNEZIA_JC" \
    AMN_JMIN="$AMNEZIA_JMIN" \
    AMN_JMAX="$AMNEZIA_JMAX" \
    AMN_S1="$AMNEZIA_S1" \
    AMN_S2="$AMNEZIA_S2" \
    python3 <<'PYEOF'
import base64, json, os, zlib

def env_str(env_name):
    """Return env var as string, defaulting to '0' if missing."""
    return os.environ.get(env_name, "0").strip() or "0"

# All AWG params are emitted as strings — the Amnezia client expects
# strings here, even for numeric values. Always include all of them so
# the wire format from this URI exactly mirrors what we wrote into the
# server-side awg0.conf (and into client.conf below); a missing key
# would let the client default to something else, which would mean a
# mismatched handshake.
awg_extras = {
    "Jc":   env_str("AMN_JC"),
    "Jmin": env_str("AMN_JMIN"),
    "Jmax": env_str("AMN_JMAX"),
    "S1":   env_str("AMN_S1"),
    "S2":   env_str("AMN_S2"),
    # H1..H4 are the AmneziaWG default protocol header magics. We use
    # 1..4 in awg0.conf above, mirror them here so the URI matches.
    "H1": "1", "H2": "2", "H3": "3", "H4": "4",
}

with open(os.environ["AMN_CONF"], "r") as fh:
    config_text = fh.read()

last_config = {
    **awg_extras,
    "allowed_ips":           ["0.0.0.0/0", "::/0"],
    "client_ip":             os.environ["AMN_CLIENT_IP"],
    "client_priv_key":       os.environ["AMN_CLIENT_PRIV"],
    "config":                config_text,
    "hostName":              os.environ["AMN_PUBLIC_IP"],
    "mtu":                   "1420",
    "persistent_keep_alive": "25",
    "port":                  int(os.environ["AMN_PORT"]),
    "psk_key":               os.environ["AMN_PSK"],
    "server_pub_key":        os.environ["AMN_SERVER_PUB"],
}

amnezia_config = {
    "containers": [{
        "awg": {
            "isThirdPartyConfig": True,
            "last_config":        json.dumps(last_config),
            "port":               os.environ["AMN_PORT"],
            "transport_proto":    "udp",
        },
        "container": "amnezia-awg",
    }],
    "defaultContainer": "amnezia-awg",
    "description":      "lazy-vps",
    "dns1":             "1.1.1.1",
    "dns2":             "1.0.0.1",
    "hostName":         os.environ["AMN_PUBLIC_IP"],
}

payload = json.dumps(amnezia_config, indent=4).encode()
header  = len(payload).to_bytes(4, "big")
encoded = base64.urlsafe_b64encode(header + zlib.compress(payload)).decode().rstrip("=")

with open(os.environ["AMN_OUT"], "w") as fh:
    fh.write("vpn://" + encoded + "\n")
PYEOF
    chmod 644 /opt/amnezia/vpn.uri

    # --- QR encodes the vpn:// URI (one-tap import in the Amnezia VPN app) ---
    qrencode -t PNG -o /opt/amnezia/client.png < /opt/amnezia/vpn.uri || true
    chmod 644 /opt/amnezia/client.png 2>/dev/null || true

    systemctl enable awg-quick@awg0
    # `awg-quick up` can race with the kernel module loading on the very
    # first boot; retry a couple times rather than failing the whole script.
    for attempt in 1 2 3; do
      if systemctl restart awg-quick@awg0; then
        echo "AmneziaWG up on attempt $attempt"
        break
      fi
      echo "awg-quick@awg0 failed (attempt $attempt), retrying in 5s…"
      sleep 5
    done
    systemctl status awg-quick@awg0 --no-pager || true

    echo "=== AmneziaWG setup complete ==="
    echo "Listening on UDP/$AMNEZIA_PORT"
    echo "Server pubkey: $SERVER_PUB"
    echo "Client config: /opt/amnezia/client.conf"
    echo "Amnezia link:  /opt/amnezia/vpn.uri"
    echo "Amnezia QR:    /opt/amnezia/client.png"
  }

  if amnezia_setup; then
    :
  else
    echo "!!! AmneziaWG setup failed; VLESS/MTProto/bot are unaffected." >&2
    echo "    Inspect /var/log/xray-setup.log and re-run by hand." >&2
  fi
  set -e
else
  echo ""
  echo "=== AmneziaWG: skipped (amnezia_enabled=false) ==="
fi
