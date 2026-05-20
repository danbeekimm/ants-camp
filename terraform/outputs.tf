# ============================================================
# Outputs
# ============================================================

output "gateway_public_ip" {
  description = "gateway-ec2 퍼블릭 EIP (도메인 연결 대상)"
  value       = aws_eip.gateway.public_ip
}

output "kafka_private_ip" {
  description = "kafka-ec2 프라이빗 IP"
  value       = aws_instance.kafka.private_ip
}

output "infra_private_ip" {
  description = "infra-ec2 프라이빗 IP (Config: 8888, Eureka: 8761)"
  value       = aws_instance.infra.private_ip
}

output "app_private_ip" {
  description = "app-ec2 프라이빗 IP (user:8082, asset:8086, ranking:8094, trade:8084, competition:8092, notification:8098, assistant:8096)"
  value       = aws_instance.app.private_ip
}

output "monitoring_private_ip" {
  description = "monitoring-ec2 사설 IP (Loki:3100 - 내부 Promtail 연결용)"
  value       = aws_instance.monitoring.private_ip
}

output "monitoring_public_ip" {
  description = "monitoring-ec2 퍼블릭 EIP (Grafana:3000 외부 접근용)"
  value       = aws_eip.monitoring.public_ip
}

output "grafana_public_url" {
  description = "Grafana 외부 접속 URL (admin_cidr에서만 허용)"
  value       = "http://${aws_eip.monitoring.public_ip}:3000"
}

output "db_private_ip" {
  description = "db-ec2 private IP (Redis:6379)"
  value       = aws_instance.db.private_ip
}

output "eureka_url" {
  description = "Eureka Dashboard URL (내부 접근)"
  value       = "http://${aws_instance.infra.private_ip}:8761"
}

output "ssh_bastion_command" {
  description = "gateway-ec2 SSH 접속 명령어"
  value       = "ssh -i ~/.ssh/${var.key_name}.pem ubuntu@${aws_eip.gateway.public_ip}"
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}
