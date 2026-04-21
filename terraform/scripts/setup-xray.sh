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
# lazy-vps-ctl: host-side helper for the bot
# ============================================
# Runs as root on the host, listens on a Unix socket via systemd socket activation.
# The unprivileged bot container only gets the socket mounted in; it cannot
# execute arbitrary commands, only the exact verbs enumerated below.

mkdir -p /var/run/lazy-vps-ctl
chmod 755 /var/run/lazy-vps-ctl

cat > /usr/local/sbin/lazy-vps-ctl <<'CTL'
#!/bin/bash
# Reads a single line from stdin, writes a single line to stdout.
# Protocol:
#   restart xray   -> OK restarted | ERR <msg>
#   restart telemt -> OK restarted | ERR <msg>
#   status  xray   -> OK <active|inactive|...> | ERR <msg>
set -u
read -r line || { printf 'ERR empty request\n'; exit 0; }
set -- $line
verb="$${1:-}"
target="$${2:-}"
one_line() { tr '\n' ' ' | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $$//'; }
case "$verb:$target" in
  restart:xray)
    if out=$(systemctl restart xray 2>&1); then
      printf 'OK restarted\n'
    else
      printf 'ERR %s\n' "$(printf '%s' "$out" | one_line)"
    fi
    ;;
  restart:telemt)
    if out=$(docker restart telemt 2>&1); then
      printf 'OK restarted\n'
    else
      printf 'ERR %s\n' "$(printf '%s' "$out" | one_line)"
    fi
    ;;
  status:xray)
    state=$(systemctl is-active xray 2>/dev/null || true)
    printf 'OK %s\n' "$${state:-unknown}"
    ;;
  *)
    printf 'ERR unknown command: %s %s\n' "$verb" "$target"
    ;;
esac
CTL
chmod 755 /usr/local/sbin/lazy-vps-ctl

cat > /etc/systemd/system/lazy-vps-ctl.socket <<'UNIT'
[Unit]
Description=lazy-vps-ctl helper socket

[Socket]
ListenStream=/var/run/lazy-vps-ctl/lazy-vps-ctl.sock
SocketMode=0660
SocketUser=root
SocketGroup=docker
Accept=yes

[Install]
WantedBy=sockets.target
UNIT

cat > '/etc/systemd/system/lazy-vps-ctl@.service' <<'UNIT'
[Unit]
Description=lazy-vps-ctl helper (per-connection)

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/lazy-vps-ctl
StandardInput=socket
StandardOutput=socket
StandardError=journal
TimeoutStartSec=30
UNIT

systemctl daemon-reload
systemctl enable --now lazy-vps-ctl.socket

# ============================================
# Telegram Bot (lazy-vps-bot)
# ============================================

mkdir -p /opt/lazy-vps-bot

# Bot source (templated in by Terraform).
cat > /opt/lazy-vps-bot/bot.py <<'BOTPY'
${bot_py}
BOTPY
chmod 644 /opt/lazy-vps-bot/bot.py

# Environment file consumed by docker compose. Mode 600 because it contains the token.
cat > /opt/lazy-vps-bot/bot.env <<BOTENV
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
ALLOWED_USERS_JSON=$TELEGRAM_ALLOWED_USERS
AWS_REGION=$AWS_REGION
XRAY_UUID=$XRAY_UUID
XRAY_SHORT_ID=$XRAY_SHORT_ID
CAMOUFLAGE_DOMAIN=$CAMOUFLAGE_DOMAIN
MTPROTO_PORT=$MTPROTO_PORT
XRAY_PUBLIC_KEY_PATH=/data/xray/public_key.txt
XRAY_ACCESS_LOG=/data/xray/access.log
TG_LINK_PATH=/data/telemt/tg_link.txt
CTL_SOCKET=/data/ctl/lazy-vps-ctl.sock
BOTENV
chmod 600 /opt/lazy-vps-bot/bot.env

cat > /opt/lazy-vps-bot/Dockerfile <<'DOCKERFILE'
FROM python:3.12-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates docker.io \
 && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir \
    "python-telegram-bot==21.6" \
    "boto3>=1.34,<2"

WORKDIR /app
COPY bot.py /app/bot.py

# Runs as root inside the container but with cap_drop: ALL,
# no-new-privileges, and a read-only filesystem (see docker-compose.yml).
# Root is required to read xray access.log (root-only) and to use the
# docker socket / ctl socket.
ENTRYPOINT ["python", "-u", "/app/bot.py"]
DOCKERFILE

cat > /opt/lazy-vps-bot/docker-compose.yml <<'COMPOSE'
services:
  bot:
    build: .
    image: lazy-vps-bot:latest
    container_name: lazy-vps-bot
    restart: unless-stopped
    env_file:
      - ./bot.env
    volumes:
      - /usr/local/etc/xray:/data/xray:ro
      - /var/log/xray:/data/xray-logs:ro
      - /opt/telemt:/data/telemt:ro
      - /var/run/lazy-vps-ctl:/data/ctl
      - /var/run/docker.sock:/var/run/docker.sock
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    read_only: true
    tmpfs:
      - /tmp:rw,nosuid,nodev,size=16m
    deploy:
      resources:
        limits:
          cpus: "0.50"
          memory: 256M
COMPOSE

# Point the bot at the right access log path inside the container.
sed -i 's|^XRAY_ACCESS_LOG=.*|XRAY_ACCESS_LOG=/data/xray-logs/access.log|' /opt/lazy-vps-bot/bot.env

cd /opt/lazy-vps-bot
docker compose up -d --build

echo ""
echo "=== lazy-vps-bot setup complete ==="
echo "Allowed users: $TELEGRAM_ALLOWED_USERS"
