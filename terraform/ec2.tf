# ============================================================
# EC2 Instances
# 생성 순서(Terraform 의존성 그래프 기준):
#   kafka → infra → domain / domain2 / notification
#   → monitoring / db / gateway
# ============================================================

# ──────────────────────────────────────────────────────────────
# 1. kafka-ec2  (KRaft, t3.small, private subnet)
# ──────────────────────────────────────────────────────────────
resource "aws_instance" "kafka" {
  ami                    = var.ami_id
  instance_type          = "t3.small"
  subnet_id              = aws_subnet.private.id
  key_name               = local.key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2_s3.name
  vpc_security_group_ids = [aws_security_group.kafka.id]

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/user_data/kafka.sh.tpl", {
    aws_region            = var.aws_region
    s3_bucket             = var.s3_bucket_name
    kafka_heap            = var.kafka_heap_size          # 256m
    kafka_broker_port     = var.ports["kafka_broker"]
    kafka_controller_port = var.ports["kafka_controller"]
    node_exporter_port    = var.ports["node_exporter"]
    promtail_port         = var.ports["promtail"]
    loki_ip               = var.monitoring_private_ip
    loki_port             = var.ports["loki"]
    node_id               = "1"
  })

  tags = { Name = "${var.project_name}-kafka-ec2" }
}

# ──────────────────────────────────────────────────────────────
# 2. infra-ec2  (Config Server + Eureka + Kafka UI, t3.small, private)
# ──────────────────────────────────────────────────────────────
resource "aws_instance" "infra" {
  ami                    = var.ami_id
  instance_type          = "t3.small"
  subnet_id              = aws_subnet.private.id
  key_name               = local.key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2_s3.name
  vpc_security_group_ids = [aws_security_group.infra.id]

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/user_data/infra.sh.tpl", {
    aws_region          = var.aws_region
    s3_bucket           = var.s3_bucket_name
    kafka_ip            = aws_instance.kafka.private_ip
    kafka_port          = var.ports["kafka_broker"]
    config_server_jar   = var.jar_keys["config_server"]
    eureka_jar          = var.jar_keys["eureka_server"]
    kafka_ui_jar        = var.jar_keys["kafka_ui"]
    config_server_port  = var.ports["config_server"]
    eureka_port         = var.ports["eureka"]
    kafka_ui_port       = var.ports["kafka_ui"]
    config_git_uri      = var.config_git_uri
    config_git_username = var.config_git_username
    config_git_password = var.config_git_password
    node_exporter_port  = var.ports["node_exporter"]
    promtail_port       = var.ports["promtail"]
    loki_ip             = var.monitoring_private_ip
    loki_port           = var.ports["loki"]
    # Docker / JVM
    docker_image        = var.docker_java_image
    docker_mem_limit    = var.docker_memory_limit
    heap_config_server  = var.jvm_heap["default"]
    heap_eureka         = var.jvm_heap["eureka"]
    heap_kafka_ui       = var.jvm_heap["default"]
    tomcat_threads      = var.tomcat_max_threads
    hikari_pool         = var.hikari_max_pool_size
  })

  tags = { Name = "${var.project_name}-infra-ec2" }
}

# ──────────────────────────────────────────────────────────────
# 3. app-ec2  (user, asset, ranking, trade, competition,
#              notification, assistant — t3.xlarge, private)
# ──────────────────────────────────────────────────────────────
resource "aws_instance" "app" {
  ami                    = var.ami_id
  instance_type          = "t3.medium"
  subnet_id              = aws_subnet.private.id
  key_name               = local.key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2_s3.name
  vpc_security_group_ids = [aws_security_group.app.id]

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 40
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/user_data/app.sh.tpl", {
    aws_region         = var.aws_region
    project_name       = var.project_name
    infra_ip           = aws_instance.infra.private_ip
    kafka_ip           = aws_instance.kafka.private_ip
    config_server_port = var.ports["config_server"]
    eureka_port        = var.ports["eureka"]
    kafka_port         = var.ports["kafka_broker"]
    user_port          = var.ports["user"]
    asset_port         = var.ports["asset"]
    ranking_port       = var.ports["ranking"]
    trade_port         = var.ports["trade"]
    competition_port   = var.ports["competition"]
    notification_port  = var.ports["notification"]
    assistant_port     = var.ports["assistant"]
    node_exporter_port = var.ports["node_exporter"]
    promtail_port      = var.ports["promtail"]
    loki_ip            = var.monitoring_private_ip
    loki_port          = var.ports["loki"]
  })

  tags = { Name = "${var.project_name}-app-ec2" }
}

# ──────────────────────────────────────────────────────────────
# 6. monitoring-ec2  (Prometheus + Grafana + Loki, t3.small, private)
# ──────────────────────────────────────────────────────────────
resource "aws_instance" "monitoring" {
  ami                    = var.ami_id
  instance_type          = "t3.small"
  subnet_id              = aws_subnet.public.id
  key_name               = local.key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2_s3.name
  vpc_security_group_ids = [aws_security_group.monitoring.id]
  private_ip             = var.monitoring_private_ip

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/user_data/monitoring.sh.tpl", {
    aws_region          = var.aws_region
    project_name        = var.project_name
    prometheus_port     = var.ports["prometheus"]
    grafana_port        = var.ports["grafana"]
    loki_port           = var.ports["loki"]
    node_exporter_port  = var.ports["node_exporter"]
    promtail_port       = var.ports["promtail"]
    kafka_ip            = aws_instance.kafka.private_ip
    infra_ip            = aws_instance.infra.private_ip
    app_ip              = aws_instance.app.private_ip
    db_ip               = aws_instance.db.private_ip
    gateway_ip          = aws_instance.gateway.private_ip
    config_server_port  = var.ports["config_server"]
    eureka_port         = var.ports["eureka"]
    user_port           = var.ports["user"]
    asset_port          = var.ports["asset"]
    ranking_port        = var.ports["ranking"]
    trade_port          = var.ports["trade"]
    competition_port    = var.ports["competition"]
    notification_port   = var.ports["notification"]
    assistant_port      = var.ports["assistant"]
  })

  depends_on = [
    aws_instance.kafka,
    aws_instance.infra,
    aws_instance.app,
    aws_instance.db,
    aws_instance.gateway,
  ]

  tags = { Name = "${var.project_name}-monitoring-ec2" }
}

# ──────────────────────────────────────────────────────────────
# 7. db-ec2  (Redis only, t3.micro, private) - PostgreSQL은 Aurora RDS로 이관
# ──────────────────────────────────────────────────────────────
resource "aws_instance" "db" {
  ami                    = var.ami_id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.private.id
  key_name               = local.key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2_s3.name
  vpc_security_group_ids = [aws_security_group.db.id]

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/user_data/db.sh.tpl", {
    redis_port         = var.ports["redis"]
    node_exporter_port = var.ports["node_exporter"]
    promtail_port      = var.ports["promtail"]
    loki_ip            = var.monitoring_private_ip
    loki_port          = var.ports["loki"]
  })

  tags = { Name = "${var.project_name}-db-ec2" }
}

# ──────────────────────────────────────────────────────────────
# 8. gateway-ec2  (nginx + bastion, t3.micro, public)
# ──────────────────────────────────────────────────────────────
resource "aws_instance" "gateway" {
  ami                    = var.ami_id
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.public.id
  key_name               = local.key_name
  iam_instance_profile   = aws_iam_instance_profile.ec2_s3.name
  vpc_security_group_ids = [aws_security_group.gateway.id]

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/user_data/gateway.sh.tpl", {
    aws_region         = var.aws_region
    app_ip             = aws_instance.app.private_ip
    infra_ip           = aws_instance.infra.private_ip
    user_port          = var.ports["user"]
    asset_port         = var.ports["asset"]
    ranking_port       = var.ports["ranking"]
    trade_port         = var.ports["trade"]
    competition_port   = var.ports["competition"]
    notification_port  = var.ports["notification"]
    assistant_port     = var.ports["assistant"]
    eureka_port        = var.ports["eureka"]
    kafka_ui_port      = var.ports["kafka_ui"]
    node_exporter_port = var.ports["node_exporter"]
    promtail_port      = var.ports["promtail"]
    loki_ip            = var.monitoring_private_ip
    loki_port          = var.ports["loki"]
  })

  tags = { Name = "${var.project_name}-gateway-ec2" }
}
