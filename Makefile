SHELL := /bin/bash
.DEFAULT_GOAL := help

TF_DIR := terraform
SSH_KEY := $(HOME)/.ssh/id_ed25519

# Resolve which host the SSH-using targets should connect to. When Tailscale
# is configured for this deployment the public SSH port is closed, so we MUST
# go over the tailnet. Your local machine must also be on the tailnet; if it
# isn't, `tailscale status` on your laptop will tell you.
# When Tailscale is not configured, fall back to the public Elastic IP.
RESOLVE_HOST = TS_ENABLED=$$(cd $(TF_DIR) && terraform output -raw tailscale_enabled 2>/dev/null || echo false); \
	if [ "$$TS_ENABLED" = "true" ]; then \
		HOST=$$(cd $(TF_DIR) && terraform output -raw tailscale_hostname 2>/dev/null || echo lazy-vps); \
	else \
		HOST=$$(cd $(TF_DIR) && terraform output -raw server_ip); \
	fi

# Remote script fed to `ssh ... bash -s` by the `users` target.
# Expects env vars: MONTH_START (Telemt --since), XRAY_DATE (awk prefix), TOP.
define USERS_SCRIPT
set -eu

# --- 1. Collect IPs per service ---
if sudo test -s /var/log/xray/access.log; then
    XRAY_DATA=$$(sudo awk -v start="$$XRAY_DATE" \
        '$$1 >= start && $$3 == "from" { ip = $$4; sub(/:.*/, "", ip); print ip }' \
        /var/log/xray/access.log | sort | uniq -c | sort -rn)
else
    XRAY_DATA=""
fi
XRAY_TOTAL=$$(printf '%s\n' "$$XRAY_DATA" | awk 'NF' | wc -l | tr -d ' ')

TELEMT_DATA=$$(sudo docker logs telemt --since "$$MONTH_START" 2>&1 \
    | sed 's/\x1b\[[0-9;]*m//g' \
    | grep -oE 'peer=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
    | cut -d= -f2 | sort | uniq -c | sort -rn)
TELEMT_TOTAL=$$(printf '%s\n' "$$TELEMT_DATA" | awk 'NF' | wc -l | tr -d ' ')

# --- 2. Batch GeoIP lookup via ip-api.com (chunks of 100) ---
ALL_IPS=$$(printf '%s\n%s\n' "$$XRAY_DATA" "$$TELEMT_DATA" | awk 'NF {print $$2}' | sort -u)
BATCHES=$$(printf '%s\n' "$$ALL_IPS" | awk '
    NF {
        if (n == 0) batch = "[\"" $$1 "\""; else batch = batch ",\"" $$1 "\""
        n++
        if (n == 100) { print batch "]"; n = 0 }
    }
    END { if (n > 0) print batch "]" }')

GEO_TSV=""
if [ -n "$$BATCHES" ]; then
    while IFS= read -r batch; do
        [ -z "$$batch" ] && continue
        RESP=$$(curl -s -m 15 -X POST -H 'Content-Type: application/json' \
            --data "$$batch" \
            'http://ip-api.com/batch?fields=status,query,countryCode,city,isp,as' 2>/dev/null || echo '[]')
        CHUNK=$$(printf '%s' "$$RESP" | jq -r '.[]? | select(.status=="success") | [
            .query,
            (if (.city // "") != "" then (.city + ", " + .countryCode) else (.countryCode // "?") end),
            (.isp // .as // "?")] | @tsv' 2>/dev/null || true)
        GEO_TSV="$$GEO_TSV$$CHUNK
"
    done <<< "$$BATCHES"
fi
export GEO_TSV

# --- 3. Render ---
render_section() {
    local title="$$1" data="$$2" total="$$3"
    echo ""
    echo "$$title — unique client IPs: $$total"
    if [ -z "$$data" ] || [ "$$total" -eq 0 ]; then
        echo "  (no data)"
        return
    fi
    echo "$$data" | awk -v top="$$TOP" '
        BEGIN {
            n = split(ENVIRON["GEO_TSV"], lines, "\n")
            for (i = 1; i <= n; i++) {
                ln = lines[i]
                if (length(ln) == 0) continue
                p1 = index(ln, "\t"); if (p1 == 0) continue
                ip = substr(ln, 1, p1-1)
                rest = substr(ln, p1+1)
                p2 = index(rest, "\t")
                if (p2 == 0) { loc[ip] = rest; isp[ip] = "?" }
                else { loc[ip] = substr(rest, 1, p2-1); isp[ip] = substr(rest, p2+1) }
            }
            printf "  %6s  %-15s  %-22s  %s\n", "conns", "IP", "Location", "ISP"
        }
        {
            if (top != "0" && NR > top+0) { over++; next }
            l = (ip=$$2) in loc ? loc[$$2] : "?"
            s = (ip=$$2) in isp ? isp[$$2] : "?"
            if (length(l) > 22) l = substr(l, 1, 20) ".."
            if (length(s) > 38) s = substr(s, 1, 36) ".."
            printf "  %6s  %-15s  %-22s  %s\n", $$1, $$2, l, s
        }
        END {
            if (over > 0) printf "  … +%d more (set TOP=0 to show all)\n", over
        }
    '
}

if [ "$$XRAY_TOTAL" -eq 0 ]; then
    echo ""
    echo "VLESS VPN (Xray) — no connections logged yet this month"
    echo "  (access logging was enabled recently; data will accrue going forward)"
else
    render_section "VLESS VPN (Xray)" "$$XRAY_DATA" "$$XRAY_TOTAL"
fi
render_section "Telegram Proxy (Telemt)" "$$TELEMT_DATA" "$$TELEMT_TOTAL"
endef
export USERS_SCRIPT

# ──────────────────────────────────────────────
# Setup
# ──────────────────────────────────────────────

.PHONY: check
check: ## Check that all prerequisites are installed
	@echo "Checking prerequisites..."
	@command -v aws >/dev/null 2>&1 || { echo "❌ AWS CLI not found. Install: brew install awscli"; exit 1; }
	@echo "  ✓ AWS CLI $$(aws --version 2>&1 | awk '{print $$1}')"
	@command -v terraform >/dev/null 2>&1 || { echo "❌ Terraform not found. Install: brew install terraform"; exit 1; }
	@echo "  ✓ Terraform $$(terraform --version -json 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)["terraform_version"])' 2>/dev/null || terraform --version | head -1 | awk '{print $$2}')"
	@aws sts get-caller-identity >/dev/null 2>&1 || { echo "❌ AWS credentials not configured. Run: make aws-configure"; exit 1; }
	@echo "  ✓ AWS credentials configured (account: $$(aws sts get-caller-identity --query Account --output text))"
	@test -f $(SSH_KEY).pub || { echo "❌ SSH key not found at $(SSH_KEY).pub. Run: make ssh-keygen"; exit 1; }
	@echo "  ✓ SSH key found at $(SSH_KEY).pub"
	@echo "All good! Run 'make deploy' to launch your VPS."

.PHONY: check-bot-env
check-bot-env: ## Check that Telegram bot env vars are set
	@[ -n "$$TF_VAR_telegram_bot_token" ] || { \
		echo "❌ TF_VAR_telegram_bot_token is not set."; \
		echo "   Create a bot with @BotFather, then:"; \
		echo "     export TF_VAR_telegram_bot_token='123456:ABCDEF...'"; \
		exit 1; }
	@[ -n "$$TF_VAR_telegram_allowed_users" ] || { \
		echo "❌ TF_VAR_telegram_allowed_users is not set."; \
		echo "   Example:"; \
		echo "     export TF_VAR_telegram_allowed_users='[\"alice\",\"123456789\"]'"; \
		exit 1; }
	@echo "  ✓ TF_VAR_telegram_bot_token is set"
	@echo "  ✓ TF_VAR_telegram_allowed_users=$$TF_VAR_telegram_allowed_users"

.PHONY: aws-configure
aws-configure: ## Configure AWS CLI credentials
	aws configure

.PHONY: ssh-keygen
ssh-keygen: ## Generate an SSH key pair if you don't have one
	@test -f $(SSH_KEY) && echo "SSH key already exists at $(SSH_KEY)" || ssh-keygen -t ed25519 -f $(SSH_KEY) -N "" -C "lazy-vps"

.PHONY: setup
setup: check init ## Full first-time setup: check prerequisites + terraform init

# ──────────────────────────────────────────────
# Terraform
# ──────────────────────────────────────────────

.PHONY: init
init: ## Initialize Terraform (download providers)
	cd $(TF_DIR) && terraform init

.PHONY: plan
plan: ## Preview changes without applying
	cd $(TF_DIR) && terraform plan

.PHONY: deploy
deploy: check-bot-env ## Deploy the VPS (terraform apply)
	cd $(TF_DIR) && terraform apply
	@echo ""
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "VPS deployed! Wait 3-4 minutes for setup"
	@echo "to finish, then run:"
	@echo ""
	@echo "  make vless-link    # VPN connection link"
	@echo "  make tg-link       # Telegram proxy link"
	@echo "  make amnezia-link  # AmneziaWG client config (only if enabled)"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

.PHONY: destroy
destroy: ## Tear down everything (terraform destroy)
	cd $(TF_DIR) && terraform destroy

.PHONY: output
output: ## Show all Terraform outputs
	cd $(TF_DIR) && terraform output

# ──────────────────────────────────────────────
# VPN
# ──────────────────────────────────────────────

.PHONY: vless-link
vless-link: ## Get the VLESS connection link(s). Reality always; CF-WS too if enabled.
	@IP=$$(cd $(TF_DIR) && terraform output -raw server_ip) && \
	$(RESOLVE_HOST) && SSH_HOST=$$HOST && \
	UUID=$$(cd $(TF_DIR) && terraform output -raw xray_uuid) && \
	SID=$$(cd $(TF_DIR) && terraform output -raw xray_short_id) && \
	SNI=$$(cd $(TF_DIR) && terraform output -raw camouflage_domain) && \
	CF_ENABLED=$$(cd $(TF_DIR) && terraform output -raw cloudflare_enabled 2>/dev/null || echo false) && \
	PBK=$$(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no ubuntu@$$SSH_HOST 'cat /usr/local/etc/xray/public_key.txt' 2>/dev/null) && \
	[ -n "$$PBK" ] || { echo "❌ Could not retrieve public key. Server may still be starting — wait a minute and try again."; exit 1; } && \
	REALITY_LINK="vless://$$UUID@$$IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$$SNI&fp=chrome&pbk=$$PBK&sid=$$SID&type=tcp#lazy-vps-reality" && \
	echo "" && \
	echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" && \
	echo "VLESS Reality link (direct, primary):" && \
	echo "" && \
	echo "$$REALITY_LINK" && \
	if [ "$$CF_ENABLED" = "true" ]; then \
		CF_DOMAIN=$$(cd $(TF_DIR) && terraform output -raw cloudflare_domain 2>/dev/null) && \
		CF_PATH=$$(cd $(TF_DIR) && terraform output -raw cloudflare_ws_path 2>/dev/null) && \
		[ -n "$$CF_DOMAIN" ] && [ -n "$$CF_PATH" ] || { echo "❌ Cloudflare flag is on but cloudflare_domain / ws_path output is missing."; exit 1; } && \
		ENCODED_PATH=$$(printf '%s' "$$CF_PATH" | python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.stdin.read(), safe=""), end="")') && \
		CF_LINK="vless://$$UUID@$$CF_DOMAIN:443?encryption=none&security=tls&sni=$$CF_DOMAIN&fp=chrome&type=ws&host=$$CF_DOMAIN&path=$$ENCODED_PATH#lazy-vps-cf" && \
		echo "" && \
		echo "VLESS Cloudflare-WS link (fallback when Reality is throttled):" && \
		echo "" && \
		echo "$$CF_LINK" && \
		echo "" && \
		echo "Distribute both. Most clients (Hiddify Next, v2rayN) can be set" && \
		echo "to try them in order; if Reality is rate-limited, CF-WS takes over."; \
	fi && \
	echo "" && \
	echo "Import these links into your client app:" && \
	echo "  iOS:     Streisand / V2Box" && \
	echo "  macOS:   V2Box / Hiddify Next" && \
	echo "  Android: v2rayNG / Hiddify Next" && \
	echo "  Windows: v2rayN" && \
	echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" && \
	echo "" && \
	echo "For Telegram proxy link, run: make tg-link"

.PHONY: tg-link
tg-link: ## Get the Telegram proxy link (run ~4 min after deploy)
	@$(RESOLVE_HOST) && \
	TG_LINK=$$(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no ubuntu@$$HOST 'cat /opt/telemt/tg_link.txt' 2>/dev/null) && \
	echo "" && \
	echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" && \
	echo "Telegram Proxy Link:" && \
	echo "" && \
	echo "$$TG_LINK" && \
	echo "" && \
	echo "Open this link on your phone/desktop" && \
	echo "and Telegram will offer to enable the proxy." && \
	echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" || \
	{ echo "❌ Could not retrieve Telegram link. Server may still be starting — wait a minute and try again."; exit 1; }

.PHONY: amnezia-link
amnezia-link: ## Get the AmneziaWG vpn:// link + .conf (run ~5-6 min after deploy)
	@AMN_ENABLED=$$(cd $(TF_DIR) && terraform output -raw amnezia_enabled 2>/dev/null || echo false); \
	if [ "$$AMN_ENABLED" != "true" ]; then \
		echo "❌ AmneziaWG is disabled."; \
		echo "   Set 'export TF_VAR_amnezia_enabled=true' in .envrc and re-run 'make deploy'."; \
		exit 1; \
	fi; \
	$(RESOLVE_HOST); \
	OUT_CONF="amnezia-client.conf"; \
	OUT_URI="amnezia-client.vpn"; \
	REMOTE_CMD='sudo cat /opt/amnezia/vpn.uri && echo "---" && sudo cat /opt/amnezia/client.conf'; \
	BLOB=$$(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no ubuntu@$$HOST "$$REMOTE_CMD" 2>/dev/null); \
	if [ -z "$$BLOB" ]; then \
		echo "❌ Could not retrieve AmneziaWG config. Server may still be starting — wait a minute and try again."; \
		echo "   (AmneziaWG installs *after* Xray and Telemt, so it's the last thing to come up.)"; \
		exit 1; \
	fi; \
	URI=$$(printf '%s\n' "$$BLOB" | awk '/^---$$/{exit} {print}'); \
	CONF=$$(printf '%s\n' "$$BLOB" | awk 'p{print} /^---$$/{p=1}'); \
	printf '%s\n' "$$URI"  > "$$OUT_URI"; \
	printf '%s\n' "$$CONF" > "$$OUT_CONF"; \
	echo ""; \
	echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"; \
	echo "AmneziaWG link (one-tap import in Amnezia VPN app):"; \
	echo ""; \
	echo "$$URI"; \
	echo ""; \
	echo "Saved:"; \
	echo "  $$OUT_URI   ← Amnezia VPN app: paste / scan QR / send the .vpn file"; \
	echo "  $$OUT_CONF  ← AmneziaWG / WireGuard apps: import as config file"; \
	echo ""; \
	echo "QR code (for phone import): make amnezia-qr"; \
	echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

.PHONY: amnezia-qr
amnezia-qr: ## Download the AmneziaWG QR code as amnezia-client.png
	@AMN_ENABLED=$$(cd $(TF_DIR) && terraform output -raw amnezia_enabled 2>/dev/null || echo false); \
	if [ "$$AMN_ENABLED" != "true" ]; then \
		echo "❌ AmneziaWG is disabled. Set TF_VAR_amnezia_enabled=true and re-deploy."; exit 1; \
	fi; \
	$(RESOLVE_HOST); \
	scp -q -o StrictHostKeyChecking=no ubuntu@$$HOST:/opt/amnezia/client.png amnezia-client.png 2>/dev/null && \
	echo "Saved QR code to amnezia-client.png" || \
	{ echo "❌ Could not retrieve QR. Server may still be starting."; exit 1; }

.PHONY: amnezia-status
amnezia-status: ## Check AmneziaWG interface status (peers, last handshake, transfer)
	@AMN_ENABLED=$$(cd $(TF_DIR) && terraform output -raw amnezia_enabled 2>/dev/null || echo false); \
	if [ "$$AMN_ENABLED" != "true" ]; then \
		echo "❌ AmneziaWG is disabled."; exit 1; \
	fi; \
	$(RESOLVE_HOST) && \
	ssh -o StrictHostKeyChecking=no ubuntu@$$HOST 'sudo systemctl is-active awg-quick@awg0 && sudo awg show awg0'

.PHONY: tg-status
tg-status: ## Check Telemt (Telegram proxy) container status
	@$(RESOLVE_HOST) && \
	ssh -o StrictHostKeyChecking=no ubuntu@$$HOST 'sudo docker ps -f name=telemt && echo "" && sudo docker compose -f /opt/telemt/docker-compose.yml logs --tail=20'

.PHONY: ssh
ssh: ## SSH into the VPS
	@$(RESOLVE_HOST) && \
	ssh -o StrictHostKeyChecking=no ubuntu@$$HOST

.PHONY: logs
logs: ## Stream Xray logs from the VPS
	@$(RESOLVE_HOST) && \
	ssh -o StrictHostKeyChecking=no ubuntu@$$HOST 'sudo journalctl -u xray -f'

.PHONY: setup-log
setup-log: ## View the cloud-init setup log
	@$(RESOLVE_HOST) && \
	ssh -o StrictHostKeyChecking=no ubuntu@$$HOST 'cat /var/log/xray-setup.log'

.PHONY: status
status: ## Check if Xray is running on the VPS
	@$(RESOLVE_HOST) && \
	ssh -o StrictHostKeyChecking=no ubuntu@$$HOST 'sudo systemctl status xray --no-pager'

# ──────────────────────────────────────────────
# Telegram Bot
# ──────────────────────────────────────────────

.PHONY: bot-status
bot-status: ## Show lazy-vps-bot container status and recent logs
	@$(RESOLVE_HOST) && \
	ssh -o StrictHostKeyChecking=no ubuntu@$$HOST 'sudo docker ps -f name=lazy-vps-bot && echo "" && sudo docker logs --tail=30 lazy-vps-bot'

.PHONY: bot-logs
bot-logs: ## Follow lazy-vps-bot container logs
	@$(RESOLVE_HOST) && \
	ssh -o StrictHostKeyChecking=no ubuntu@$$HOST 'sudo docker logs -f --tail=50 lazy-vps-bot'

.PHONY: bot-restart
bot-restart: ## Restart the lazy-vps-bot container
	@$(RESOLVE_HOST) && \
	ssh -o StrictHostKeyChecking=no ubuntu@$$HOST 'sudo docker restart lazy-vps-bot'

.PHONY: bot-install
bot-install: check-bot-env ## Install/upgrade the bot on an already-deployed VPS (no reboot, no Xray/Telemt impact)
	@set -e; \
	$(RESOLVE_HOST); \
	XRAY_UUID=$$(cd $(TF_DIR) && terraform output -raw xray_uuid); \
	XRAY_SHORT_ID=$$(cd $(TF_DIR) && terraform output -raw xray_short_id); \
	CAMOUFLAGE_DOMAIN=$$(cd $(TF_DIR) && terraform output -raw camouflage_domain); \
	MTPROTO_PORT=$$(cd $(TF_DIR) && terraform output -raw mtproto_port); \
	AWS_REGION=$$(cd $(TF_DIR) && terraform output -raw aws_region 2>/dev/null || echo eu-north-1); \
	AMNEZIA_ENABLED=$$(cd $(TF_DIR) && terraform output -raw amnezia_enabled 2>/dev/null || echo false); \
	[ "$$AMNEZIA_ENABLED" = "true" ] && AMNEZIA_ENV=true || AMNEZIA_ENV=; \
	echo "Uploading bot.py and install-bot.sh to $$HOST…"; \
	scp -q -o StrictHostKeyChecking=no \
		$(TF_DIR)/scripts/bot.py \
		$(TF_DIR)/scripts/install-bot.sh \
		ubuntu@$$HOST:/tmp/; \
	echo "Running installer remotely…"; \
	ssh -o StrictHostKeyChecking=no ubuntu@$$HOST "sudo mkdir -p /opt/lazy-vps-bot && \
		sudo mv /tmp/bot.py /opt/lazy-vps-bot/bot.py && \
		sudo mv /tmp/install-bot.sh /opt/lazy-vps-bot/install-bot.sh && \
		sudo chmod 755 /opt/lazy-vps-bot/install-bot.sh && \
		sudo env \
			TELEGRAM_BOT_TOKEN='$$TF_VAR_telegram_bot_token' \
			TELEGRAM_ALLOWED_USERS='$$TF_VAR_telegram_allowed_users' \
			AWS_REGION='$$AWS_REGION' \
			XRAY_UUID='$$XRAY_UUID' \
			XRAY_SHORT_ID='$$XRAY_SHORT_ID' \
			CAMOUFLAGE_DOMAIN='$$CAMOUFLAGE_DOMAIN' \
			MTPROTO_PORT='$$MTPROTO_PORT' \
			AMNEZIA_ENABLED='$$AMNEZIA_ENV' \
			BOT_PY_PATH=/opt/lazy-vps-bot/bot.py \
			/opt/lazy-vps-bot/install-bot.sh"
	@echo ""
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "Bot installed/updated. Check:"
	@echo "  make bot-status"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

.PHONY: bot-update
bot-update: ## Fast path: sync bot.py only and restart the container (no config re-render)
	@set -e; \
	$(RESOLVE_HOST); \
	echo "Uploading bot.py to $$HOST…"; \
	scp -q -o StrictHostKeyChecking=no $(TF_DIR)/scripts/bot.py ubuntu@$$HOST:/tmp/bot.py; \
	ssh -o StrictHostKeyChecking=no ubuntu@$$HOST 'sudo mv /tmp/bot.py /opt/lazy-vps-bot/bot.py && \
		sudo chmod 644 /opt/lazy-vps-bot/bot.py && \
		cd /opt/lazy-vps-bot && sudo docker compose up -d --build'
	@echo "Bot updated."

# ──────────────────────────────────────────────
# Monitoring
# ──────────────────────────────────────────────

.PHONY: traffic
traffic: ## Show network traffic used this month (CloudWatch, month-to-date)
	@set -e; \
	INSTANCE_ID=$$(aws ec2 describe-instances \
		--filters "Name=tag:Name,Values=lazy-vps" "Name=instance-state-name,Values=running" \
		--query 'Reservations[0].Instances[0].InstanceId' --output text); \
	[ -n "$$INSTANCE_ID" ] && [ "$$INSTANCE_ID" != "None" ] || { echo "❌ No running lazy-vps instance found."; exit 1; }; \
	START=$$(date -u +"%Y-%m-01T00:00:00Z"); \
	END=$$(date -u +"%Y-%m-%dT%H:%M:%SZ"); \
	MONTH=$$(date -u +"%B %Y"); \
	sum_metric() { \
		aws cloudwatch get-metric-statistics \
			--namespace AWS/EC2 --metric-name "$$1" \
			--dimensions Name=InstanceId,Value=$$INSTANCE_ID \
			--start-time "$$START" --end-time "$$END" \
			--period 86400 --statistics Sum \
			--query 'Datapoints[].Sum' --output text \
		| tr '\t' '\n' | awk '{s+=$$1} END {printf "%.0f\n", s+0}'; \
	}; \
	IN_BYTES=$$(sum_metric NetworkIn); \
	OUT_BYTES=$$(sum_metric NetworkOut); \
	REGION=$$(aws configure get region 2>/dev/null || echo "unknown"); \
	awk -v i="$$IN_BYTES" -v o="$$OUT_BYTES" -v m="$$MONTH" -v id="$$INSTANCE_ID" -v region="$$REGION" 'BEGIN { \
		g=1024*1024*1024; \
		free_gb = 100; \
		rate = 0.09; \
		out_gb = o/g; \
		free_left = free_gb - out_gb; if (free_left < 0) free_left = 0; \
		billable = out_gb - free_gb; if (billable < 0) billable = 0; \
		cost = billable * rate; \
		printf "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"; \
		printf "Traffic for %s (month-to-date)\n", m; \
		printf "Instance: %s  (%s)\n\n", id, region; \
		printf "  In:    %7.2f GB  (free)\n", i/g; \
		printf "  Out:   %7.2f GB\n", out_gb; \
		printf "  Total: %7.2f GB\n", (i+o)/g; \
		printf "\nBilling estimate (data transfer out to internet):\n"; \
		printf "  Free tier:    %6.2f GB / %.0f GB (account-wide, always-free)\n", (out_gb < free_gb ? out_gb : free_gb), free_gb; \
		printf "  Free left:    %6.2f GB\n", free_left; \
		printf "  Billable:     %6.2f GB  @ $$%.2f/GB\n", billable, rate; \
		printf "  Est. cost:    $$%.2f\n", cost; \
		printf "\n  Note: rate assumes first 10 TB tier (same in eu-north-1, eu-central-1, eu-west-*).\n"; \
		printf "        EC2 instance-hours and EBS storage are billed separately.\n"; \
		printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n" \
	}'

.PHONY: destinations
destinations: ## Top destination domains accessed via VPN this month (TOP=N for count, TOP=0 for all)
	@set -e; \
	IP=$$(cd $(TF_DIR) && terraform output -raw server_ip); \
	$(RESOLVE_HOST); SSH_HOST=$$HOST; \
	MONTH_LABEL=$$(date -u +"%B %Y"); \
	XRAY_DATE=$$(date -u +"%Y/%m/01"); \
	TOP=$${TOP:-20}; \
	printf "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"; \
	printf "Destinations for %s (month-to-date)\n" "$$MONTH_LABEL"; \
	printf "Server: %s\n" "$$IP"; \
	DATA=$$(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no ubuntu@$$SSH_HOST \
		"if sudo test -s /var/log/xray/access.log; then \
			sudo awk -v start='$$XRAY_DATE' '\$$1 >= start && \$$5 == \"accepted\" {print \$$6}' /var/log/xray/access.log \
			| sed -E 's/^[^:]+://; s/:[0-9]+\$$//; s/^\\[|\\]\$$//g' \
			| sort | uniq -c | sort -rn; \
		 fi"); \
	TOTAL=$$(printf '%s\n' "$$DATA" | awk 'NF' | wc -l | tr -d ' '); \
	if [ "$$TOTAL" -eq 0 ]; then \
		printf "\n  No traffic logged yet this month.\n"; \
		printf "  (Xray access logging was enabled recently; data will accrue going forward.)\n"; \
	else \
		printf "Unique destinations: %s\n\n" "$$TOTAL"; \
		printf "  %9s  %s\n" "conns" "destination"; \
		echo "$$DATA" | awk -v top="$$TOP" '\
			top == "0" || NR <= top+0 {printf "  %9s  %s\n", $$1, $$2; next} \
			{over++} \
			END {if (over) printf "  … +%d more (set TOP=0 to show all)\n", over}'; \
	fi; \
	printf "\n  Note: destinations are TLS SNI / HTTP Host sniffed by Xray.\n"; \
	printf "        Aggregate across all clients (not per-IP).\n"; \
	printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"

.PHONY: users
users: ## List unique client IPs that used VPN/TG proxy this month (TOP=N for count, TOP=0 for all)
	@set -e; \
	IP=$$(cd $(TF_DIR) && terraform output -raw server_ip); \
	$(RESOLVE_HOST); SSH_HOST=$$HOST; \
	MONTH_LABEL=$$(date -u +"%B %Y"); \
	MONTH_START=$$(date -u +"%Y-%m-01T00:00:00"); \
	XRAY_DATE=$$(date -u +"%Y/%m/01"); \
	TOP=$${TOP:-10}; \
	printf "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"; \
	printf "Users for %s (month-to-date)\n" "$$MONTH_LABEL"; \
	printf "Server: %s\n" "$$IP"; \
	ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no ubuntu@$$SSH_HOST \
		"MONTH_START='$$MONTH_START' XRAY_DATE='$$XRAY_DATE' TOP='$$TOP' bash -s" \
		<<< "$$USERS_SCRIPT"; \
	printf "\n  Showing top %s per service. Set TOP=N or TOP=0 (all).\n" "$$TOP"; \
	printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"

# NOTE: `users` and `destinations` cover Xray and Telemt only. AmneziaWG
# stats live in `sudo awg show awg0` and key by client pubkey, not IP, so
# they don't fold cleanly into the IP-keyed report. For now the raw view
# is in `make amnezia-status`; if we ever wire up multiple AmneziaWG peers
# with friendly names, this is where to integrate them.

# ──────────────────────────────────────────────
# Help
# ──────────────────────────────────────────────

.PHONY: help
help: ## Show this help
	@echo "lazy-vps — Personal VLESS Reality VPN on AWS"
	@echo ""
	@echo "Usage: make <target>"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Quick start:"
	@echo "  make setup       # Check prereqs + init terraform"
	@echo "  make deploy      # Launch the VPS"
	@echo "  make vless-link  # Get VPN link (~3 min after deploy)"
	@echo "  make tg-link     # Get Telegram proxy link (~4 min after deploy)"
	@echo "  make destroy     # Tear it all down"
