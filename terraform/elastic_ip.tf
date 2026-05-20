# ============================================================
# Elastic IP - gateway-ec2 (도메인 연결용 고정 IP)
# ============================================================

resource "aws_eip" "gateway" {
  domain   = "vpc"
  instance = aws_instance.gateway.id

  depends_on = [aws_internet_gateway.main]

  tags = { Name = "${var.project_name}-eip-gateway" }
}

# ============================================================
# Elastic IP - monitoring-ec2 (Grafana 외부 접근용)
# ============================================================

resource "aws_eip" "monitoring" {
  domain   = "vpc"
  instance = aws_instance.monitoring.id

  depends_on = [aws_internet_gateway.main]

  tags = { Name = "${var.project_name}-eip-monitoring" }
}
