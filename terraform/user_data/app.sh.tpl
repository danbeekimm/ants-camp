#!/bin/bash
# ============================================================
# app-ec2 초기화 스크립트 (t3.xlarge)
# 담당 서비스: user, asset, ranking, trade, competition,
#              notification, assistant
# 배포 방식: ECR 이미지 → docker run (systemd 관리)
# ============================================================
set -euo pipefail
exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1

echo "===== [app-ec2] START: $(date) ====="

# ── 기본 패키지 ───────────────────────────────────────────────
apt-get update -y
apt-get install -y curl wget unzip jq awscli ca-certificates gnupg lsb-release

# ── Docker 설치 ───────────────────────────────────────────────
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
systemctl enable docker
systemctl start docker
usermod -aG docker ubuntu
echo "Docker: $(docker --version)"

# ── SSM Agent 설치 (원격 접속용) ────────────────────────────
snap install amazon-ssm-agent --classic || true
systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent
systemctl start  snap.amazon-ssm-agent.amazon-ssm-agent

# ── ECR 로그인 헬퍼 (cron으로 11시간마다 갱신) ───────────────
AWS_REGION="${aws_region}"
ECR_REGISTRY="$(aws sts get-caller-identity --query Account --output text).dkr.ecr.$${AWS_REGION}.amazonaws.com"
PROJECT="${project_name}"

ecr_login() {
  aws ecr get-login-password --region "$AWS_REGION" \
    | docker login --username AWS --password-stdin "$ECR_REGISTRY"
}
ecr_login

# cron: 11시간마다 ECR 토큰 갱신
echo "0 */11 * * * root aws ecr get-login-password --region $${AWS_REGION} | docker login --username AWS --password-stdin $${ECR_REGISTRY} >> /var/log/ecr-login.log 2>&1" \
  > /etc/cron.d/ecr-login

# ── 디렉토리 설정 ────────────────────────────────────────────
mkdir -p /opt/ants-camp /opt/logs
chown ubuntu:ubuntu /opt/ants-camp /opt/logs

# ── EC2 Private IP 조회 (Eureka 등록용) ─────────────────────
PRIVATE_IP=$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4)

# ── 공통 환경변수 파일 생성 ──────────────────────────────────
# 서비스별 민감한 값(JWT, API 키 등)은 배포 시 SSM으로 주입
cat > /opt/ants-camp/common.env <<ENV
AWS_REGION=${aws_region}
SPRING_PROFILES_ACTIVE=prod
EUREKA_CLIENT_SERVICEURL_DEFAULTZONE=http://${infra_ip}:${eureka_port}/eureka/
EUREKA_INSTANCE_PREFERIPADDRESS=true
EUREKA_INSTANCE_IPADDRESS=$${PRIVATE_IP}
CONFIG_SERVER_URL=http://${infra_ip}:${config_server_port}
SPRING_KAFKA_BOOTSTRAP_SERVERS=${kafka_ip}:${kafka_port}
ZIPKIN_ENDPOINT=http://${loki_ip}:9411/api/v2/spans
JAVA_TOOL_OPTIONS=-Xms256m -Xmx512m
ENV
chmod 600 /opt/ants-camp/common.env

# ── 서비스 배포 함수 ─────────────────────────────────────────
deploy_service() {
  local NAME=$1
  local PORT=$2
  local IMAGE="$ECR_REGISTRY/$PROJECT/$${NAME}:latest"

  echo "Pulling $NAME from ECR..."
  docker pull "$IMAGE" || { echo "WARN: $NAME pull failed, skipping"; return 0; }

  cat > /etc/systemd/system/$${NAME}.service <<SVC
[Unit]
Description=$${NAME} (ECR)
After=docker.service
Requires=docker.service

[Service]
Restart=on-failure
RestartSec=15
ExecStartPre=-/usr/bin/docker stop $${NAME}
ExecStartPre=-/usr/bin/docker rm   $${NAME}
ExecStart=/usr/bin/docker run --name $${NAME} \\
  --env-file /opt/ants-camp/common.env \\
  --env-file /opt/ants-camp/$${NAME}.env \\
  -p $${PORT}:$${PORT} \\
  -v /opt/logs:/opt/logs \\
  $${IMAGE}
ExecStop=/usr/bin/docker stop $${NAME}

[Install]
WantedBy=multi-user.target
SVC
}

# ── 서비스별 기본 .env 파일 (상세 값은 SSM 배포로 주입) ──────
for SVC in user-service asset-service ranking-service trade-service competition-service notification-service assistant-service; do
  touch /opt/ants-camp/$${SVC}.env
  chmod 600 /opt/ants-camp/$${SVC}.env
done

# 포트 설정
cat >> /opt/ants-camp/user-service.env        <<< "SERVER_PORT=${user_port}"$'\n'"EUREKA_INSTANCE_PORT=${user_port}"
cat >> /opt/ants-camp/asset-service.env       <<< "SERVER_PORT=${asset_port}"$'\n'"EUREKA_INSTANCE_PORT=${asset_port}"
cat >> /opt/ants-camp/ranking-service.env     <<< "SERVER_PORT=${ranking_port}"$'\n'"EUREKA_INSTANCE_PORT=${ranking_port}"
cat >> /opt/ants-camp/trade-service.env       <<< "SERVER_PORT=${trade_port}"$'\n'"EUREKA_INSTANCE_PORT=${trade_port}"
cat >> /opt/ants-camp/competition-service.env <<< "SERVER_PORT=${competition_port}"$'\n'"EUREKA_INSTANCE_PORT=${competition_port}"
cat >> /opt/ants-camp/notification-service.env<<< "SERVER_PORT=${notification_port}"$'\n'"EUREKA_INSTANCE_PORT=${notification_port}"
cat >> /opt/ants-camp/assistant-service.env   <<< "SERVER_PORT=${assistant_port}"$'\n'"EUREKA_INSTANCE_PORT=${assistant_port}"

# ── 서비스 systemd 등록 ──────────────────────────────────────
deploy_service "user-service"         ${user_port}
deploy_service "asset-service"        ${asset_port}
deploy_service "ranking-service"      ${ranking_port}
deploy_service "trade-service"        ${trade_port}
deploy_service "competition-service"  ${competition_port}
deploy_service "notification-service" ${notification_port}
deploy_service "assistant-service"    ${assistant_port}

systemctl daemon-reload
systemctl enable user-service asset-service ranking-service \
                trade-service competition-service \
                notification-service assistant-service
systemctl start  user-service asset-service ranking-service \
                trade-service competition-service \
                notification-service assistant-service || true

# ── Node Exporter ─────────────────────────────────────────────
NE_VER="1.8.0"
wget -q "https://github.com/prometheus/node_exporter/releases/download/v$${NE_VER}/node_exporter-$${NE_VER}.linux-amd64.tar.gz" \
  -O /tmp/node_exporter.tgz
tar -xzf /tmp/node_exporter.tgz -C /tmp/
mv /tmp/node_exporter-$${NE_VER}.linux-amd64/node_exporter /usr/local/bin/

cat > /etc/systemd/system/node_exporter.service <<EOF
[Unit]
Description=Prometheus Node Exporter
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/node_exporter --web.listen-address=:${node_exporter_port}
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable node_exporter
systemctl start  node_exporter

# ── Promtail (Docker 컨테이너 로그 → Loki) ───────────────────
mkdir -p /etc/promtail
cat > /etc/promtail/config.yaml <<EOF
server:
  http_listen_port: ${promtail_port}
  grpc_listen_port: 0
positions:
  filename: /tmp/promtail-positions.yaml
clients:
  - url: http://${loki_ip}:${loki_port}/loki/api/v1/push
scrape_configs:
  - job_name: docker
    docker_sd_configs:
      - host: unix:///var/run/docker.sock
        refresh_interval: 5s
    relabel_configs:
      - source_labels: [__meta_docker_container_name]
        regex: '/?(.*)'
        target_label: job
      - source_labels: [__meta_docker_container_name]
        target_label: container
    pipeline_stages:
      - docker: {}
EOF

docker run -d \
  --name promtail \
  --restart unless-stopped \
  -v /etc/promtail/config.yaml:/etc/promtail/config.yaml \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /tmp:/tmp \
  grafana/promtail:3.1.0 \
  -config.file=/etc/promtail/config.yaml

echo "===== [app-ec2] DONE: $(date) ====="
