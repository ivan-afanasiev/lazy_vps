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
