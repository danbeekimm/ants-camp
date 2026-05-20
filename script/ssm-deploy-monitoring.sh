#!/bin/bash
# ============================================================
# SSM Run Command - 모니터링 EC2 배포 스크립트
# ECR 토큰을 로컬에서 발급 → SSM으로 EC2에 전달
# EC2에 AWS CLI 없어도 동작합니다.
#
# 사용법:
#   ./script/ssm-deploy-monitoring.sh                       # 전체 서비스
#   ./script/ssm-deploy-monitoring.sh grafana              # 단일 서비스
#   ./script/ssm-deploy-monitoring.sh --instance-id i-xxxx # 인스턴스 직접 지정
#
# 사전 조건:
#   - 로컬: AWS CLI + ECR 권한
#   - EC2 : docker 설치, SSM Agent 실행 중
#           (EC2에 AWS CLI 불필요)
# ============================================================

set -euo pipefail

# ── 설정 ─────────────────────────────────────────────────────
AWS_REGION="ap-northeast-2"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
ECR_PREFIX="ants-camp"

INSTANCE_TAG_KEY="Name"
INSTANCE_TAG_VALUE="antcamp-monitoring"

# EC2에 배포될 compose 파일 경로
COMPOSE_FILE="/opt/ants-camp/monitoring/docker-compose.yml"
# 로컬 compose 파일 경로 (여기서 읽어서 EC2에 씀)
LOCAL_COMPOSE_FILE="monitoring/docker-compose.yml"
SSM_TIMEOUT=300

ECR_SERVICES=("grafana" "prometheus" "loki" "zipkin" "alertmanager")

# ── 인자 파싱 ─────────────────────────────────────────────────
INSTANCE_ID=""
TARGET_SERVICE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --instance-id) INSTANCE_ID="$2"; shift 2 ;;
    -h|--help)
      echo "사용법: $0 [service-name] [--instance-id i-xxxx]"
      echo ""
      echo "  인자 없음    : 전체 서비스 재배포"
      echo "  service-name : grafana | prometheus | loki | zipkin | alertmanager | node-exporter"
      echo "  --instance-id: EC2 인스턴스 ID 직접 지정 (생략 시 태그로 자동 탐색)"
      exit 0 ;;
    -*) echo "❌ 알 수 없는 옵션: $1"; exit 1 ;;
    *)  TARGET_SERVICE="$1"; shift ;;
  esac
done

# ── EC2 인스턴스 탐색 ─────────────────────────────────────────
find_instance_id() {
  echo "🔍 EC2 탐색 (태그 ${INSTANCE_TAG_KEY}=${INSTANCE_TAG_VALUE})..." >&2
  local id
  id=$(aws ec2 describe-instances \
    --region "$AWS_REGION" \
    --filters \
      "Name=tag:${INSTANCE_TAG_KEY},Values=${INSTANCE_TAG_VALUE}" \
      "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].InstanceId" \
    --output text)

  if [ "$id" = "None" ] || [ -z "$id" ]; then
    echo "❌ 인스턴스를 찾을 수 없습니다 (태그: ${INSTANCE_TAG_KEY}=${INSTANCE_TAG_VALUE})" >&2
    echo "   --instance-id 옵션으로 직접 지정하세요." >&2
    exit 1
  fi
  echo "   → ${id}" >&2
  echo "$id"
}

# ── SSM 명령 전송 & 폴링 ──────────────────────────────────────
run_ssm_command() {
  local INSTANCE_ID=$1
  local COMMANDS_JSON=$2
  local COMMENT=$3

  echo ""
  echo "📡 SSM 명령 전송: ${COMMENT}"

  local COMMAND_ID
  COMMAND_ID=$(aws ssm send-command \
    --region "$AWS_REGION" \
    --instance-ids "$INSTANCE_ID" \
    --document-name "AWS-RunShellScript" \
    --comment "$COMMENT" \
    --timeout-seconds "$SSM_TIMEOUT" \
    --parameters "commands=${COMMANDS_JSON}" \
    --query "Command.CommandId" \
    --output text)

  echo "   CommandId: ${COMMAND_ID}"
  echo -n "   대기 중"

  local STATUS="Pending"
  local DOTS=0
  while [ "$STATUS" = "InProgress" ] || [ "$STATUS" = "Pending" ]; do
    sleep 5
    STATUS=$(aws ssm get-command-invocation \
      --region "$AWS_REGION" \
      --command-id "$COMMAND_ID" \
      --instance-id "$INSTANCE_ID" \
      --query "Status" \
      --output text 2>/dev/null || echo "Pending")
    printf "."
    DOTS=$((DOTS + 1))
    if [ "$DOTS" -ge 60 ]; then
      echo ""
      echo "⚠️  타임아웃. AWS 콘솔에서 CommandId ${COMMAND_ID} 를 확인하세요."
      exit 1
    fi
  done
  echo ""

  local OUTPUT
  OUTPUT=$(aws ssm get-command-invocation \
    --region "$AWS_REGION" \
    --command-id "$COMMAND_ID" \
    --instance-id "$INSTANCE_ID" \
    --query "{Status:Status,Output:StandardOutputContent,Error:StandardErrorContent}" \
    --output json)

  local STATUS_FINAL STD_OUT STD_ERR
  STATUS_FINAL=$(echo "$OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['Status'])")
  STD_OUT=$(echo "$OUTPUT"     | python3 -c "import sys,json; print(json.load(sys.stdin)['Output'])")
  STD_ERR=$(echo "$OUTPUT"     | python3 -c "import sys,json; print(json.load(sys.stdin)['Error'])")

  echo "── 실행 결과 ────────────────────────────────────────"
  [ -n "$STD_OUT" ] && echo "$STD_OUT"
  if [ -n "$STD_ERR" ]; then
    echo "── stderr ───────────────────────────────────────────"
    echo "$STD_ERR"
  fi
  echo "─────────────────────────────────────────────────────"

  if [ "$STATUS_FINAL" != "Success" ]; then
    echo "❌ 명령 실패 (Status: ${STATUS_FINAL})"
    exit 1
  fi
  echo "✅ 완료 (Status: ${STATUS_FINAL})"
}

# ── compose 파일 인코딩 ───────────────────────
encode_compose_file() {
  if [ ! -f "$LOCAL_COMPOSE_FILE" ]; then
    echo "❌ 로컬 compose 파일 없음: ${LOCAL_COMPOSE_FILE}" >&2
    exit 1
  fi
  sed \
    -e "s|\${AWS_ACCOUNT_ID}|${AWS_ACCOUNT_ID}|g" \
    -e "s|\${AWS_REGION}|${AWS_REGION}|g" \
    "$LOCAL_COMPOSE_FILE" | base64 | tr -d '\n'
}

# EC2에서 compose / .env 를 복원하는 공통 헤더
compose_write_block() {
  local COMPOSE_B64=$1
  cat <<BLOCK
echo "=== compose 파일 배포 ==="
mkdir -p "\$(dirname ${COMPOSE_FILE})"
echo "${COMPOSE_B64}" | base64 -d > "${COMPOSE_FILE}"
echo "   → ${COMPOSE_FILE} 작성 완료"


echo "=== .env 파일 생성 ==="
cat > "\$(dirname ${COMPOSE_FILE})/.env" <<ENV
GRAFANA_ADMIN_PASSWORD=${GRAFANA_ADMIN_PASSWORD}
SLACK_ALERTMANAGER_WEBHOOK_URL=${SLACK_WEBHOOK_URL}
WEBHOOK_SHARED_SECRET=${WEBHOOK_SHARED_SECRET}
AWS_ACCOUNT_ID=${AWS_ACCOUNT_ID}
AWS_REGION=${AWS_REGION}
ENV
chmod 600 "\$(dirname ${COMPOSE_FILE})/.env"
echo "   → .env 작성 완료"
BLOCK
}

# ── 명령 스크립트 생성 ────────────────────────────────────────
# ECR 토큰을 로컬에서 발급 → EC2에서 docker login에 직접 사용
# EC2에 aws CLI 불필요, docker만 있으면 됨

make_script_all() {
  local ECR_PASSWORD=$1
  local COMPOSE_B64=$2

  cat <<SCRIPT
set -e
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin

DOCKER=\$(command -v docker || echo "/usr/bin/docker")

$(compose_write_block "$COMPOSE_B64")

echo "=== ECR 로그인 ==="
echo "${ECR_PASSWORD}" | \$DOCKER login --username AWS --password-stdin "${ECR_REGISTRY}"

echo "=== 이미지 Pull ==="
for SVC in grafana prometheus loki zipkin alertmanager; do
  echo "  pulling ${ECR_REGISTRY}/${ECR_PREFIX}/\${SVC}:latest"
  \$DOCKER pull "${ECR_REGISTRY}/${ECR_PREFIX}/\${SVC}:latest"
done

echo "=== 컨테이너 재시작 ==="
\$DOCKER compose -f "${COMPOSE_FILE}" --env-file "\$(dirname ${COMPOSE_FILE})/.env" up -d

echo "=== 실행 중인 컨테이너 ==="
\$DOCKER compose -f "${COMPOSE_FILE}" --env-file "\$(dirname ${COMPOSE_FILE})/.env" ps
SCRIPT
}

make_script_single_ecr() {
  local SVC=$1
  local ECR_PASSWORD=$2
  local COMPOSE_B64=$3

  cat <<SCRIPT
set -e
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin

DOCKER=\$(command -v docker || echo "/usr/bin/docker")

$(compose_write_block "$COMPOSE_B64")

echo "=== ECR 로그인 ==="
echo "${ECR_PASSWORD}" | \$DOCKER login --username AWS --password-stdin "${ECR_REGISTRY}"

echo "=== 이미지 Pull: ${SVC} ==="
\$DOCKER pull "${ECR_REGISTRY}/${ECR_PREFIX}/${SVC}:latest"

echo "=== 컨테이너 재시작: ${SVC} ==="
\$DOCKER compose -f "${COMPOSE_FILE}" --env-file "\$(dirname ${COMPOSE_FILE})/.env" up -d --no-deps ${SVC}

echo "=== 상태 확인 ==="
\$DOCKER compose -f "${COMPOSE_FILE}" --env-file "\$(dirname ${COMPOSE_FILE})/.env" ps ${SVC}
SCRIPT
}

make_script_single_official() {
  local SVC=$1
  local COMPOSE_B64=$2

  cat <<SCRIPT
set -e
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin

DOCKER=\$(command -v docker || echo "/usr/bin/docker")

$(compose_write_block "$COMPOSE_B64")

echo "=== 컨테이너 재시작: ${SVC} ==="
\$DOCKER compose -f "${COMPOSE_FILE}" --env-file "\$(dirname ${COMPOSE_FILE})/.env" up -d --no-deps ${SVC}

echo "=== 상태 확인 ==="
\$DOCKER compose -f "${COMPOSE_FILE}" --env-file "\$(dirname ${COMPOSE_FILE})/.env" ps ${SVC}
SCRIPT
}

to_json_array() {
  python3 -c "
import sys, json
lines = sys.stdin.read().splitlines()
print(json.dumps(lines))
"
}

is_ecr_service() {
  local SVC=$1
  for s in "${ECR_SERVICES[@]}"; do
    [ "$SVC" = "$s" ] && return 0
  done
  return 1
}

# ── SSM Parameter Store에서 시크릿 조회 ──────────────────────
# 저장 방법 (최초 1회):
#   aws ssm put-parameter --name "/antcamp/monitoring/grafana_admin_password" --value "패스워드" --type SecureString --region ap-northeast-2
#   aws ssm put-parameter --name "/antcamp/monitoring/slack_webhook_url"      --value "https://hooks.slack.com/..." --type SecureString --region ap-northeast-2
#   aws ssm put-parameter --name "/antcamp/monitoring/webhook_shared_secret"  --value "시크릿" --type SecureString --region ap-northeast-2
fetch_ssm_param() {
  local PARAM_NAME=$1
  aws ssm get-parameter \
    --region "$AWS_REGION" \
    --name "$PARAM_NAME" \
    --with-decryption \
    --query "Parameter.Value" \
    --output text 2>/dev/null || echo ""
}

# ── 실행 ─────────────────────────────────────────────────────

# 인스턴스 ID 결정
if [ -z "$INSTANCE_ID" ]; then
  INSTANCE_ID=$(find_instance_id)
else
  echo "🎯 인스턴스 ID: ${INSTANCE_ID}"
fi

# SSM 연결 확인
echo "🔗 SSM 연결 확인..."
SSM_STATUS=$(aws ssm describe-instance-information \
  --region "$AWS_REGION" \
  --filters "Key=InstanceIds,Values=${INSTANCE_ID}" \
  --query "InstanceInformationList[0].PingStatus" \
  --output text 2>/dev/null || echo "Unknown")

if [ "$SSM_STATUS" != "Online" ]; then
  echo "❌ SSM Agent 오프라인 (PingStatus: ${SSM_STATUS})"
  exit 1
fi
echo "   → SSM Agent: Online ✅"

# ECR 토큰 발급 (로컬 aws CLI 사용, 유효시간 12시간)
ECR_NEEDS_TOKEN=true
if [ -n "$TARGET_SERVICE" ] && ! is_ecr_service "$TARGET_SERVICE"; then
  ECR_NEEDS_TOKEN=false
fi

ECR_PASSWORD=""
if [ "$ECR_NEEDS_TOKEN" = "true" ]; then
  echo "🔑 ECR 토큰 발급 (로컬)..."
  ECR_PASSWORD=$(aws ecr get-login-password --region "$AWS_REGION")
  echo "   → 발급 완료 (유효시간 12시간)"
fi

# SSM Parameter Store에서 시크릿 조회
echo "🔐 시크릿 조회 (SSM Parameter Store)..."
GRAFANA_ADMIN_PASSWORD=$(fetch_ssm_param "/antcamp/monitoring/grafana_admin_password")
SLACK_WEBHOOK_URL=$(fetch_ssm_param "/antcamp/monitoring/slack_webhook_url")
WEBHOOK_SHARED_SECRET=$(fetch_ssm_param "/antcamp/monitoring/webhook_shared_secret")

[ -z "$GRAFANA_ADMIN_PASSWORD" ] && echo "   ⚠️  grafana_admin_password 미설정"
[ -z "$SLACK_WEBHOOK_URL" ]      && echo "   ⚠️  slack_webhook_url 미설정"
[ -z "$WEBHOOK_SHARED_SECRET" ]  && echo "   ⚠️  webhook_shared_secret 미설정"
echo "   → 조회 완료"

# 파일 인코딩 (로컬 → base64)
echo "📄 파일 인코딩..."
COMPOSE_B64=$(encode_compose_file)
echo "   → compose 완료 (${#COMPOSE_B64} bytes)"

# 명령 스크립트 생성 및 전송
if [ -z "$TARGET_SERVICE" ]; then
  SCRIPT=$(make_script_all "$ECR_PASSWORD" "$COMPOSE_B64")
  COMMENT="antcamp monitoring - full deploy"
elif is_ecr_service "$TARGET_SERVICE"; then
  SCRIPT=$(make_script_single_ecr "$TARGET_SERVICE" "$ECR_PASSWORD" "$COMPOSE_B64")
  COMMENT="antcamp monitoring - deploy ${TARGET_SERVICE}"
else
  SCRIPT=$(make_script_single_official "$TARGET_SERVICE" "$COMPOSE_B64")
  COMMENT="antcamp monitoring - restart ${TARGET_SERVICE}"
fi

COMMANDS_JSON=$(echo "$SCRIPT" | to_json_array)
run_ssm_command "$INSTANCE_ID" "$COMMANDS_JSON" "$COMMENT"
