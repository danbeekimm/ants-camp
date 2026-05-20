#!/bin/bash
# ============================================================
# 모니터링 시크릿 → SSM Parameter Store 등록 스크립트
# https:// 값도 file:// 방식으로 안전하게 처리합니다.
#
# 사용법:
#   ./script/ssm-put-monitoring-secrets.sh
# ============================================================

set -euo pipefail

AWS_REGION="ap-northeast-2"
PARAM_PREFIX="/antcamp/monitoring"
TMP_FILE=$(mktemp)

trap 'rm -f "$TMP_FILE"' EXIT

put_secret() {
  local NAME="${PARAM_PREFIX}/$1"
  local VALUE="$2"

  # https:// 로 시작하는 값은 AWS CLI가 URL로 해석하므로 file:// 방식 사용
  printf '%s' "$VALUE" > "$TMP_FILE"
  aws ssm put-parameter \
    --region "$AWS_REGION" \
    --name "$NAME" \
    --value "file://${TMP_FILE}" \
    --type SecureString \
    --overwrite \
    --query "Version" \
    --output text | xargs -I{} echo "   ✅ ${NAME}  (version: {})"
}

echo "🔐 SSM Parameter Store 시크릿 등록"
echo "   region: ${AWS_REGION}"
echo "   prefix: ${PARAM_PREFIX}"
echo ""

# ── Grafana admin 패스워드 ────────────────────────────────────
read -rsp "GRAFANA_ADMIN_PASSWORD: " GRAFANA_PW; echo
put_secret "grafana_admin_password" "$GRAFANA_PW"

# ── Slack Alertmanager Webhook URL ────────────────────────────
read -rsp "SLACK_ALERTMANAGER_WEBHOOK_URL: " SLACK_URL; echo
put_secret "slack_webhook_url" "$SLACK_URL"

# ── Webhook Shared Secret ─────────────────────────────────────
read -rsp "WEBHOOK_SHARED_SECRET: " WEBHOOK_SECRET; echo
put_secret "webhook_shared_secret" "$WEBHOOK_SECRET"

echo ""
echo "🎉 완료"
echo ""
echo "등록된 파라미터 확인:"
aws ssm get-parameters-by-path \
  --region "$AWS_REGION" \
  --path "$PARAM_PREFIX" \
  --query "Parameters[].{Name:Name,Version:Version,LastModified:LastModifiedDate}" \
  --output table
