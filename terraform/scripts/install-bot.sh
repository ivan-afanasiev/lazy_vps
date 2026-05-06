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
#
# IMPORTANT: When this script is executed *from inside* cloud-init's own
# user_data (i.e. by setup-xray.sh on first boot), `cloud-init status
# --wait` would deadlock — cloud-init can't finish until user_data
# returns, user_data can't return until install-bot.sh returns,
# install-bot.sh can't return until cloud-init finishes. setup-xray.sh
# sets LAZY_VPS_INSIDE_CLOUDINIT=1 to tell us to skip the wait. The
# dpkg-lock loop below still runs and is sufficient on its own to
# avoid the apt race.
if [ "${LAZY_VPS_INSIDE_CLOUDINIT:-}" != "1" ] && command -v cloud-init >/dev/null 2>&1; then
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
#   restart xray      -> OK restarted | ERR <msg>
#   restart telemt    -> OK restarted | ERR <msg>
#   restart amnezia   -> OK restarted | ERR <msg>
#   restart tailscale -> OK restarted | ERR <msg>     (systemctl restart tailscaled)
#   up      tailscale -> OK up        | ERR <msg>     (tailscale up; no auth key, reuses cached identity)
#   down    tailscale -> OK down      | ERR <msg>     (tailscale down)
#   status  xray      -> OK <state>   | ERR <msg>
#   status  amnezia   -> OK <multi-line awg show>      | ERR <msg>
#   status  tailscale -> OK <multi-line ts status>     | ERR <msg>
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
  restart:amnezia)
    if out=$(systemctl restart awg-quick@awg0 2>&1); then
      printf 'OK restarted\n'
    else
      printf 'ERR %s\n' "$(printf '%s' "$out" | one_line)"
    fi
    ;;
  restart:tailscale)
    if ! command -v tailscale >/dev/null 2>&1; then
      printf 'ERR tailscale not installed\n'
      exit 0
    fi
    # Restart the daemon; the tunnel reconnects from cached config.
    if out=$(systemctl restart tailscaled 2>&1); then
      printf 'OK restarted\n'
    else
      printf 'ERR %s\n' "$(printf '%s' "$out" | one_line)"
    fi
    ;;
  up:tailscale)
    if ! command -v tailscale >/dev/null 2>&1; then
      printf 'ERR tailscale not installed\n'
      exit 0
    fi
    # `tailscale up` with no flags reuses the previously-saved login
    # state from /var/lib/tailscale/tailscaled.state — no auth key
    # needed, same hostname, same node identity. Ignore any "already
    # running" complaint and just report current status.
    if out=$(tailscale up 2>&1); then
      printf 'OK %s\n' "$(printf '%s' "$out" | one_line)"
    else
      printf 'ERR %s\n' "$(printf '%s' "$out" | one_line)"
    fi
    ;;
  down:tailscale)
    if ! command -v tailscale >/dev/null 2>&1; then
      printf 'ERR tailscale not installed\n'
      exit 0
    fi
    if out=$(tailscale down 2>&1); then
      msg=$(printf '%s' "$out" | one_line)
      printf 'OK %s\n' "${msg:-down}"
    else
      printf 'ERR %s\n' "$(printf '%s' "$out" | one_line)"
    fi
    ;;
  status:xray)
    state=$(systemctl is-active xray 2>/dev/null || true)
    printf 'OK %s\n' "${state:-unknown}"
    ;;
  status:amnezia)
    # If awg isn't installed (Amnezia disabled), return that explicitly
    # so the bot can show a useful message instead of a vague error.
    if ! command -v awg >/dev/null 2>&1; then
      printf 'ERR amneziawg not installed\n'
      exit 0
    fi
    state=$(systemctl is-active awg-quick@awg0 2>/dev/null || true)
    show=$(awg show awg0 2>&1 || true)
    # Multi-line responses are fine — the client reads until EOF on the
    # socket. Lead with the systemctl state then the awg dump.
    printf 'OK service=%s\n%s\n' "${state:-unknown}" "$show"
    ;;
  status:tailscale)
    if ! command -v tailscale >/dev/null 2>&1; then
      printf 'ERR tailscale not installed\n'
      exit 0
    fi
    state=$(systemctl is-active tailscaled 2>/dev/null || true)
    # `tailscale status` returns non-zero when the tunnel is "Stopped"
    # (after `tailscale down`), but the output is still useful — it
    # tells us the node identity. Capture stderr too, swallow the rc.
    show=$(tailscale status 2>&1 || true)
    printf 'OK daemon=%s\n%s\n' "${state:-unknown}" "$show"
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
# /opt/amnezia is created by setup-xray.sh's AmneziaWG block when the
# flag is on. When it's off the directory doesn't exist, but the bot's
# docker-compose unconditionally mounts it (read-only). Pre-create an
# empty dir so Docker's bind-mount source exists either way; the bot
# uses AMNEZIA_ENABLED to decide whether to actually look inside.
mkdir -p /opt/amnezia

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
AMNEZIA_ENABLED=${AMNEZIA_ENABLED:-}
TAILSCALE_ENABLED=${TAILSCALE_ENABLED:-}
XRAY_PUBLIC_KEY_PATH=/data/xray/public_key.txt
XRAY_ACCESS_LOG=/data/xray-logs/access.log
TG_LINK_PATH=/data/telemt/tg_link.txt
AMNEZIA_VPN_URI_PATH=/data/amnezia/vpn.uri
AMNEZIA_CLIENT_CONF_PATH=/data/amnezia/client.conf
CTL_SOCKET=/data/ctl/lazy-vps-ctl.sock
BOTENV
chmod 600 /opt/lazy-vps-bot/bot.env

cat > /opt/lazy-vps-bot/Dockerfile <<'DOCKERFILE'
FROM python:3.12-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg \
 && install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
 && chmod a+r /etc/apt/keyrings/docker.asc \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends docker-ce-cli \
 && apt-get purge -y --auto-remove curl gnupg \
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
      - /opt/amnezia:/data/amnezia:ro
      - /var/run/lazy-vps-ctl:/data/ctl
      - /var/run/docker.sock:/var/run/docker.sock
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    # Root-owned mode-600 files (xray logs are nobody:nogroup 600) need
    # DAC_READ_SEARCH to be readable from root in the container with
    # cap_drop=ALL. Keep the container otherwise fully unprivileged.
    cap_add:
      - DAC_READ_SEARCH
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
