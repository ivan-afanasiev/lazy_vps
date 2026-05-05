output "server_ip" {
  description = "Public IP address of the VPS"
  value       = aws_eip.vps.public_ip
}

output "ssh_command" {
  description = "SSH command to connect to the VPS"
  value       = "ssh ubuntu@${aws_eip.vps.public_ip}"
}

output "xray_uuid" {
  description = "VLESS client UUID"
  value       = random_uuid.xray_uuid.result
  sensitive   = true
}

output "xray_short_id" {
  description = "Reality short ID"
  value       = random_id.xray_short_id.hex
  sensitive   = true
}

output "camouflage_domain" {
  description = "SNI domain used for Reality camouflage"
  value       = var.camouflage_domain
}

output "get_vless_link" {
  description = "Run this command after deploy to get your VLESS connection link"
  value       = <<-EOT
    Run the following after cloud-init completes (~2-3 min after deploy):

    ssh ubuntu@${aws_eip.vps.public_ip} 'PUBLIC_KEY=$(cat /usr/local/etc/xray/public_key.txt) && echo "vless://${random_uuid.xray_uuid.result}@${aws_eip.vps.public_ip}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${var.camouflage_domain}&fp=chrome&pbk=$PUBLIC_KEY&sid=${random_id.xray_short_id.hex}&type=tcp#lazy-vps"'
  EOT
}

output "mtproto_port" {
  description = "Telegram MTProto proxy port"
  value       = var.mtproto_port
}

output "aws_region" {
  description = "AWS region the VPS is deployed in"
  value       = var.aws_region
}

output "get_tg_link" {
  description = "Run this command after deploy to get your Telegram proxy link"
  value       = <<-EOT
    Run the following after cloud-init completes (~3-4 min after deploy):

    ssh ubuntu@${aws_eip.vps.public_ip} 'cat /opt/telemt/tg_link.txt'
  EOT
}

output "telegram_bot_status" {
  description = "How to check the Telegram bot running on the VPS"
  value       = <<-EOT
    ssh ubuntu@${aws_eip.vps.public_ip} 'sudo docker ps -f name=lazy-vps-bot && sudo docker logs --tail=30 lazy-vps-bot'
  EOT
}

output "tailscale_enabled" {
  description = "Whether the VPS is configured to join your tailnet"
  # Comparing a sensitive value to "" produces a non-sensitive boolean (no
  # info leak), but Terraform's static check flags any output that touches
  # a sensitive var. nonsensitive() explicitly opts out — safe here because
  # we're only revealing "is the key empty or not?".
  value = nonsensitive(var.tailscale_auth_key) != ""
}

output "tailscale_hostname" {
  description = "Tailnet hostname of the VPS (only meaningful when tailscale_enabled=true)"
  value       = var.tailscale_hostname
}

output "amnezia_enabled" {
  description = "Whether AmneziaWG (obfuscated WireGuard) is configured on the VPS"
  value       = var.amnezia_enabled
}

output "amnezia_port" {
  description = "UDP port AmneziaWG listens on (only meaningful when amnezia_enabled=true)"
  value       = var.amnezia_port
}

output "get_amnezia_config" {
  description = "Run this command after deploy to fetch your AmneziaWG client config"
  value = var.amnezia_enabled ? format(
    "Run the following after cloud-init completes (~5-6 min after deploy):\n\n  ssh ubuntu@%s 'sudo cat /opt/amnezia/client.conf'\n\nOr simply:  make amnezia-link",
    aws_eip.vps.public_ip,
  ) : "AmneziaWG is disabled. Set TF_VAR_amnezia_enabled=true and re-deploy."
}
