SHELL := /bin/bash
.DEFAULT_GOAL := help

TF_DIR := terraform
SSH_KEY := $(HOME)/.ssh/id_ed25519

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
deploy: ## Deploy the VPS (terraform apply)
	cd $(TF_DIR) && terraform apply
	@echo ""
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "VPS deployed! Wait 3-4 minutes for setup"
	@echo "to finish, then run:"
	@echo ""
	@echo "  make vless-link   # VPN connection link"
	@echo "  make tg-link      # Telegram proxy link"
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
vless-link: ## Get the VLESS connection link (run ~3 min after deploy)
	@IP=$$(cd $(TF_DIR) && terraform output -raw server_ip) && \
	UUID=$$(cd $(TF_DIR) && terraform output -raw xray_uuid) && \
	SID=$$(cd $(TF_DIR) && terraform output -raw xray_short_id) && \
	SNI=$$(cd $(TF_DIR) && terraform output -raw camouflage_domain) && \
	PBK=$$(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no ubuntu@$$IP 'cat /usr/local/etc/xray/public_key.txt' 2>/dev/null) && \
	LINK="vless://$$UUID@$$IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$$SNI&fp=chrome&pbk=$$PBK&sid=$$SID&type=tcp#lazy-vps" && \
	echo "" && \
	echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" && \
	echo "VLESS Connection Link:" && \
	echo "" && \
	echo "$$LINK" && \
	echo "" && \
	echo "Import this link into your client app:" && \
	echo "  iOS:     Streisand / V2Box" && \
	echo "  macOS:   V2Box / Hiddify Next" && \
	echo "  Android: v2rayNG / Hiddify Next" && \
	echo "  Windows: v2rayN" && \
	echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" && \
	echo "" && \
	echo "For Telegram proxy link, run: make tg-link" || \
	{ echo "❌ Could not retrieve public key. Server may still be starting — wait a minute and try again."; exit 1; }

.PHONY: tg-link
tg-link: ## Get the Telegram proxy link (run ~4 min after deploy)
	@IP=$$(cd $(TF_DIR) && terraform output -raw server_ip) && \
	TG_LINK=$$(ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no ubuntu@$$IP 'cat /opt/telemt/tg_link.txt' 2>/dev/null) && \
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

.PHONY: tg-status
tg-status: ## Check Telemt (Telegram proxy) container status
	@IP=$$(cd $(TF_DIR) && terraform output -raw server_ip) && \
	ssh -o StrictHostKeyChecking=no ubuntu@$$IP 'sudo docker ps -f name=telemt && echo "" && sudo docker compose -f /opt/telemt/docker-compose.yml logs --tail=20'

.PHONY: ssh
ssh: ## SSH into the VPS
	@IP=$$(cd $(TF_DIR) && terraform output -raw server_ip) && \
	ssh -o StrictHostKeyChecking=no ubuntu@$$IP

.PHONY: logs
logs: ## Stream Xray logs from the VPS
	@IP=$$(cd $(TF_DIR) && terraform output -raw server_ip) && \
	ssh -o StrictHostKeyChecking=no ubuntu@$$IP 'sudo journalctl -u xray -f'

.PHONY: setup-log
setup-log: ## View the cloud-init setup log
	@IP=$$(cd $(TF_DIR) && terraform output -raw server_ip) && \
	ssh -o StrictHostKeyChecking=no ubuntu@$$IP 'cat /var/log/xray-setup.log'

.PHONY: status
status: ## Check if Xray is running on the VPS
	@IP=$$(cd $(TF_DIR) && terraform output -raw server_ip) && \
	ssh -o StrictHostKeyChecking=no ubuntu@$$IP 'sudo systemctl status xray --no-pager'

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
		printf "\n  Note: rate assumes first 10 TB tier (most regions, incl. eu-central-1).\n"; \
		printf "        EC2 instance-hours and EBS storage are billed separately.\n"; \
		printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n" \
	}'

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
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Quick start:"
	@echo "  make setup       # Check prereqs + init terraform"
	@echo "  make deploy      # Launch the VPS"
	@echo "  make vless-link  # Get VPN link (~3 min after deploy)"
	@echo "  make tg-link     # Get Telegram proxy link (~4 min after deploy)"
	@echo "  make destroy     # Tear it all down"
