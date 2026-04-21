#!/bin/bash
# Installs (or re-installs) the lazy-vps-bot + lazy-vps-ctl helper on a VPS.
#
# Run as root. Expects these env vars:
#   TELEGRAM_BOT_TOKEN       - bot token from @BotFather
#   TELEGRAM_ALLOWED_USERS   - JSON array of usernames / numeric IDs
#   AWS_REGION               - AWS region
#   XRAY_UUID                - VLESS UUID (from Terraform state or live xray config)
#   XRAY_SHORT_ID            - Reality short ID
#   CAMOUFLAGE_DOMAIN        - Reality SNI
#   MTPROTO_PORT             - Telegram MTProto proxy port
#   BOT_PY_PATH              - path to bot.py (default: ./bot.py, else
#                              /opt/lazy-vps-bot/bot.py if it already exists)
#
# This script is idempotent: re-running it updates files and restarts the
# bot container but does NOT touch Xray or Telemt.
set -euo pipefail

: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN is required}"
: "${TELEGRAM_ALLOWED_USERS:?TELEGRAM_ALLOWED_USERS is required (JSON array)}"
: "${AWS_REGION:?AWS_REGION is required}"
: "${XRAY_UUID:?XRAY_UUID is required}"
: "${XRAY_SHORT_ID:?XRAY_SHORT_ID is required}"
: "${CAMOUFLAGE_DOMAIN:?CAMOUFLAGE_DOMAIN is required}"
: "${MTPROTO_PORT:?MTPROTO_PORT is required}"

BOT_PY_SRC="${BOT_PY_PATH:-}"
if [ -z "$BOT_PY_SRC" ]; then
  if [ -f ./bot.py ]; then
    BOT_PY_SRC="$(pwd)/bot.py"
  elif [ -f /opt/lazy-vps-bot/bot.py ]; then
    BOT_PY_SRC=/opt/lazy-vps-bot/bot.py
  else
    echo "bot.py not found; set BOT_PY_PATH" >&2
    exit 1
  fi
fi

# --- Wait for any running apt / cloud-init to finish so we don't race
#     the dpkg lock. On a freshly-booted VPS, user-data is still running
#     apt-get upgrade when `make bot-install` is run for the first time.
if command -v cloud-init >/dev/null 2>&1; then
  cloud-init status --wait >/dev/null 2>&1 || true
fi
for i in $(seq 1 60); do
  if ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
     && ! fuser /var/lib/apt/lists/lock  >/dev/null 2>&1 \
     && ! fuser /var/lib/dpkg/lock       >/dev/null 2>&1; then
    break
  fi
  echo "Waiting for apt/dpkg lock (attempt $i/60)…"
  sleep 5
done

# --- Ensure Docker is installed (no-op if it already is) ---
if ! command -v docker >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  if [ ! -f /etc/apt/keyrings/docker.asc ]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
  fi
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable docker
  systemctl start docker
fi

# ============================================
# lazy-vps-ctl: host-side helper for the bot
# ============================================

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
verb="${1:-}"
target="${2:-}"
one_line() { tr '\n' ' ' | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//'; }
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
    printf 'OK %s\n' "${state:-unknown}"
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

# Only copy bot.py if the source is different from the destination.
if [ "$BOT_PY_SRC" != /opt/lazy-vps-bot/bot.py ]; then
  cp "$BOT_PY_SRC" /opt/lazy-vps-bot/bot.py
fi
chmod 644 /opt/lazy-vps-bot/bot.py

cat > /opt/lazy-vps-bot/bot.env <<BOTENV
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
ALLOWED_USERS_JSON=$TELEGRAM_ALLOWED_USERS
AWS_REGION=$AWS_REGION
XRAY_UUID=$XRAY_UUID
XRAY_SHORT_ID=$XRAY_SHORT_ID
CAMOUFLAGE_DOMAIN=$CAMOUFLAGE_DOMAIN
MTPROTO_PORT=$MTPROTO_PORT
XRAY_PUBLIC_KEY_PATH=/data/xray/public_key.txt
XRAY_ACCESS_LOG=/data/xray-logs/access.log
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

cd /opt/lazy-vps-bot
docker compose up -d --build

echo ""
echo "=== lazy-vps-bot install complete ==="
echo "Allowed users: $TELEGRAM_ALLOWED_USERS"
