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
PRIVATE_KEY=$(echo "$KEY_OUTPUT" | awk '/PrivateKey:/{print $2}')
PUBLIC_KEY=$(echo "$KEY_OUTPUT" | awk '/Password:/{print $2}')

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
    }
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
# We write bot.py and install-bot.sh to disk (both injected verbatim via
# Terraform ${...} expansion, NOT interpreted as shell), then run the
# installer with the bot/auth env vars set. The installer is the same code
# path used by `make bot-install` on an already-running VPS.

mkdir -p /opt/lazy-vps-bot

cat > /opt/lazy-vps-bot/bot.py <<'BOTPY'
${bot_py}
BOTPY
chmod 644 /opt/lazy-vps-bot/bot.py

cat > /opt/lazy-vps-bot/install-bot.sh <<'INSTALLBOT'
${install_bot_sh}
INSTALLBOT
chmod 755 /opt/lazy-vps-bot/install-bot.sh

TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN" \
TELEGRAM_ALLOWED_USERS="$TELEGRAM_ALLOWED_USERS" \
AWS_REGION="$AWS_REGION" \
XRAY_UUID="$XRAY_UUID" \
XRAY_SHORT_ID="$XRAY_SHORT_ID" \
CAMOUFLAGE_DOMAIN="$CAMOUFLAGE_DOMAIN" \
MTPROTO_PORT="$MTPROTO_PORT" \
BOT_PY_PATH=/opt/lazy-vps-bot/bot.py \
/opt/lazy-vps-bot/install-bot.sh
