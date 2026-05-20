#!/bin/bash
# ============================================================
# EC2 모니터링 서비스 배포 스크립트
# ECR에서 최신 이미지를 pull하고 컨테이너를 재시작합니다.
#
# ※ EC2 인스턴스에서 직접 실행하세요.
#    (IAM 역할에 ECR pull 권한 필요)
#
# 사용법:
#   ./script/deploy-monitoring-ec2.sh              # 전체 재시작
#   ./script/deploy-monitoring-ec2.sh grafana      # 단일 서비스만
#
# 실행 위치: 프로젝트 루트 (monitoring/docker-compose.yml 위치 기준)
# ============================================================

set -euo pipefail

# ── 설정 ─────────────────────────────────────────────────────
AWS_REGION="ap-northeast-2"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
ECR_PREFIX="ants-camp"
COMPOSE_FILE="monitoring/docker-compose.yml"

ECR_SERVICES=("grafana" "prometheus" "loki" "zipkin")

# ── 함수 ─────────────────────────────────────────────────────
ecr_login() {
  echo "🔐 ECR 로그인..."
  aws ecr get-login-password --region "$AWS_REGION" | \
    docker login --username AWS --password-stdin "$ECR_REGISTRY"
}

pull_image() {
  local SVC=$1
  local IMAGE="${ECR_REGISTRY}/${ECR_PREFIX}/${SVC}:latest"
  echo "📥 Pull: ${IMAGE}"
  docker pull "$IMAGE"
}

deploy_service() {
  local SVC=$1
  echo ""
  echo "🔄 재시작: ${SVC}"

  # ECR 이미지인 경우 pull
  for ecr_svc in "${ECR_SERVICES[@]}"; do
    if [ "$SVC" = "$ecr_svc" ]; then
      pull_image "$SVC"
      break
    fi
  done

  AWS_ACCOUNT_ID="$AWS_ACCOUNT_ID" AWS_REGION="$AWS_REGION" \
    docker compose -f "$COMPOSE_FILE" up -d --no-deps "$SVC"

  echo "✅ 완료: ${SVC}"
}

deploy_all() {
  echo "📥 ECR 이미지 전체 Pull..."
  for SVC in "${ECR_SERVICES[@]}"; do
    pull_image "$SVC"
  done

  echo ""
  echo "🚀 전체 모니터링 서비스 재시작..."
  AWS_ACCOUNT_ID="$AWS_ACCOUNT_ID" AWS_REGION="$AWS_REGION" \
    docker compose -f "$COMPOSE_FILE" up -d

  echo ""
  echo "📋 실행 중인 컨테이너:"
  docker compose -f "$COMPOSE_FILE" ps
}

print_usage() {
  echo "사용법: $0 [service-name]"
  echo ""
  echo "  인자 없음    : 전체 서비스 재시작"
  echo "  service-name : 해당 서비스만 재시작"
  echo ""
  echo "ECR 서비스: ${ECR_SERVICES[*]}"
  echo "공식 이미지: alertmanager, node-exporter"
}

# ── 실행 ─────────────────────────────────────────────────────
if [ ! -f "$COMPOSE_FILE" ]; then
  echo "❌ 프로젝트 루트에서 실행해주세요 ($COMPOSE_FILE 기준)"
  exit 1
fi

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  print_usage
  exit 0
fi

ecr_login

if [ $# -eq 0 ]; then
  deploy_all
else
  deploy_service "$1"
fi
