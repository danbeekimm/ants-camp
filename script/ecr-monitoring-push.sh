#!/bin/bash
# ============================================================
# 모니터링 서비스 빌드 → ECR 푸시 스크립트
# monitoring/<service>/Dockerfile 기반으로 이미지를 빌드하여 ECR에 push 합니다.
#
# 사용법:
#   ./script/ecr-monitoring-push.sh <service-name>   # 단일 서비스
#   ./script/ecr-monitoring-push.sh all              # 전체 서비스
#
# 예시:
#   ./script/ecr-monitoring-push.sh grafana
#   ./script/ecr-monitoring-push.sh prometheus
#   ./script/ecr-monitoring-push.sh loki
#   ./script/ecr-monitoring-push.sh zipkin
#   ./script/ecr-monitoring-push.sh all
# ============================================================

set -euo pipefail

# ── 설정 ─────────────────────────────────────────────────────
AWS_REGION="ap-northeast-2"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
ECR_PREFIX="ants-camp"
MONITORING_DIR="monitoring"

ALL_SERVICES=("grafana" "prometheus" "loki" "zipkin" "alertmanager")

# ── 버전 조회 함수 ────────────────────────────────────────────
get_version() {
  case "$1" in
    grafana)      echo "11.1.0" ;;
    prometheus)   echo "v2.53.0" ;;
    loki)         echo "2.9.8" ;;
    zipkin)       echo "3" ;;
    alertmanager) echo "v0.28.1" ;;
    *)            echo "" ;;
  esac
}

# ── 함수 ─────────────────────────────────────────────────────
ecr_login() {
  echo "🔐 ECR 로그인..."
  aws ecr get-login-password --region "$AWS_REGION" | \
    docker login --username AWS --password-stdin "$ECR_REGISTRY"
}

ensure_ecr_repo() {
  local REPO_NAME="${ECR_PREFIX}/$1"
  if ! aws ecr describe-repositories --region "$AWS_REGION" --repository-names "$REPO_NAME" > /dev/null 2>&1; then
    echo "📦 ECR 레포 생성: ${REPO_NAME}"
    aws ecr create-repository \
      --region "$AWS_REGION" \
      --repository-name "$REPO_NAME" \
      --image-scanning-configuration scanOnPush=true \
      --image-tag-mutability MUTABLE > /dev/null
  fi
}

build_and_push() {
  local ECR_REPO=$1
  local VERSION_TAG
  VERSION_TAG=$(get_version "$ECR_REPO")
  local CONTEXT_DIR="${MONITORING_DIR}/${ECR_REPO}"
  local DOCKERFILE="${CONTEXT_DIR}/Dockerfile"

  local ECR_IMAGE="${ECR_REGISTRY}/${ECR_PREFIX}/${ECR_REPO}:${VERSION_TAG}"
  local ECR_IMAGE_LATEST="${ECR_REGISTRY}/${ECR_PREFIX}/${ECR_REPO}:latest"

  if [ ! -f "$DOCKERFILE" ]; then
    echo "❌ Dockerfile 없음: $DOCKERFILE"
    return 1
  fi

  ensure_ecr_repo "$ECR_REPO"

  echo ""
  echo "🔨 빌드 중: ${ECR_REPO} (태그: ${VERSION_TAG})"
  docker build \
    --no-cache \
    --platform linux/amd64 \
    -f "$DOCKERFILE" \
    -t "$ECR_IMAGE" \
    -t "$ECR_IMAGE_LATEST" \
    "$CONTEXT_DIR"

  echo "📤 푸시 중: ${ECR_IMAGE}"
  docker push "$ECR_IMAGE"
  docker push "$ECR_IMAGE_LATEST"

  echo "✅ 완료: ${ECR_PREFIX}/${ECR_REPO}"
}

print_usage() {
  echo "사용법: $0 <service-name> | all"
  echo ""
  echo "서비스 목록:"
  for svc in "${ALL_SERVICES[@]}"; do
    echo "  ${svc}  (버전: $(get_version "$svc"))"
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
  echo "🚀 전체 모니터링 서비스 빌드 & 푸시 시작"
  for SVC in "${ALL_SERVICES[@]}"; do
    build_and_push "$SVC"
  done
  echo ""
  echo "🎉 전체 완료"
else
  TARGET="$1"
  VERSION_TAG=$(get_version "$TARGET")
  if [ -z "$VERSION_TAG" ]; then
    echo "❌ 알 수 없는 서비스: $TARGET"
    echo ""
    print_usage
    exit 1
  fi
  build_and_push "$TARGET"
fi
