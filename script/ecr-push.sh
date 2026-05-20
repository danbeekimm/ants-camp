#!/bin/bash
# ============================================================
# 로컬 빌드 → ECR 푸시 스크립트 (docker-compose 기반)
# 사용법:
#   ./script/ecr-push.sh <service-name>    # 단일 서비스
#   ./script/ecr-push.sh all               # 전체 서비스
#
# 예시:
#   ./script/ecr-push.sh trade-service
#   ./script/ecr-push.sh api-gateway
#   ./script/ecr-push.sh all
# ============================================================

set -euo pipefail

# ── 설정 ─────────────────────────────────────────────────────
AWS_REGION="ap-northeast-2"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
IMAGE_TAG=$(git rev-parse --short HEAD)

ALL_SERVICES=(
  "eureka-server"
  "config-server"
  "gateway-service"
  "user-service"
  "trade-service"
  "asset-service"
  "competition-service"
  "ranking-service"
  "assistant-service"
  "notification-service"
)

# docker-compose 서비스명 → ECR 리포지토리명 매핑
get_ecr_repo() {
  case "$1" in
    eureka-server)       echo "eureka-server" ;;
    config-server)       echo "config-server" ;;
    gateway-service)     echo "api-gateway" ;;
    user-service)        echo "user-service" ;;
    trade-service)       echo "trade-service" ;;
    asset-service)       echo "asset-service" ;;
    competition-service) echo "competition-service" ;;
    ranking-service)     echo "ranking-service" ;;
    assistant-service)   echo "assistant-service" ;;
    notification-service) echo "notification-service" ;;
    *)                   echo "" ;;
  esac
}

# ── 함수 ─────────────────────────────────────────────────────
ecr_login() {
  echo "🔐 ECR 로그인..."
  aws ecr get-login-password --region "$AWS_REGION" | \
    docker login --username AWS --password-stdin "$ECR_REGISTRY"
}

build_and_push() {
  local COMPOSE_SVC=$1
  local ECR_REPO
  ECR_REPO=$(get_ecr_repo "$COMPOSE_SVC")
  local ECR_IMAGE="${ECR_REGISTRY}/ants-camp/${ECR_REPO}:${IMAGE_TAG}"
  local ECR_IMAGE_LATEST="${ECR_REGISTRY}/ants-camp/${ECR_REPO}:latest"

  echo ""
  echo "🔨 빌드 중: $COMPOSE_SVC → ants-camp/$ECR_REPO (태그: $IMAGE_TAG)"

  # docker compose로 빌드
  DOCKER_DEFAULT_PLATFORM=linux/amd64 docker compose build --no-cache "$COMPOSE_SVC"

  # 빌드된 이미지 이름 찾기 (project명-service명)
  PROJECT_NAME=$(basename "$(pwd)" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g')
  LOCAL_IMAGE="${PROJECT_NAME}-${COMPOSE_SVC}"

  # ECR 태그 추가
  docker tag "$LOCAL_IMAGE" "$ECR_IMAGE"
  docker tag "$LOCAL_IMAGE" "$ECR_IMAGE_LATEST"

  echo "📤 푸시 중: $ECR_IMAGE"
  docker push "$ECR_IMAGE"
  docker push "$ECR_IMAGE_LATEST"

  echo "✅ 완료: ants-camp/$ECR_REPO"
}

print_usage() {
  echo "사용법: $0 <service-name> | all"
  echo ""
  echo "서비스 목록:"
  for svc in "${ALL_SERVICES[@]}"; do
    echo "  $svc → ants-camp/$(get_ecr_repo "$svc")"
  done
}

# ── 실행 ─────────────────────────────────────────────────────
if [ $# -eq 0 ]; then
  print_usage
  exit 1
fi

# 프로젝트 루트 확인
if [ ! -f "docker-compose.yml" ]; then
  echo "❌ 프로젝트 루트에서 실행해주세요 (docker-compose.yml 위치)"
  exit 1
fi

ecr_login

if [ "$1" = "all" ]; then
  echo "🚀 전체 서비스 빌드 & 푸시 시작"
  for COMPOSE_SVC in "${ALL_SERVICES[@]}"; do
    build_and_push "$COMPOSE_SVC"
  done
  echo ""
  echo "🎉 전체 완료"
else
  TARGET="$1"
  ECR_REPO=$(get_ecr_repo "$TARGET")
  if [ -z "$ECR_REPO" ]; then
    echo "❌ 알 수 없는 서비스: $TARGET"
    echo ""
    print_usage
    exit 1
  fi
  build_and_push "$TARGET"
fi
