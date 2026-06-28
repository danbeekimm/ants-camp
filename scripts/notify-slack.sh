#!/usr/bin/env bash
#
# notify-slack.sh — antcamp 개발자에게 작업 결과를 Slack Incoming Webhook으로 보고한다.
#
# 사용:
#   scripts/notify-slack.sh --status success --title "제목" --text "본문"
#   scripts/notify-slack.sh --status failure --title "제목" --file path/to/summary.md
#   echo "본문" | scripts/notify-slack.sh --status success --title "제목"
#
# 옵션:
#   --status  success | failure | info   (기본 info)  → 색상/이모지 결정
#   --title   메시지 제목 (필수 권장)
#   --text    본문 텍스트
#   --file    본문을 읽어올 파일 (없으면 --text 또는 stdin 사용)
#
# 웹훅 URL: 환경변수 CLAUDE_DEV_SLACK_WEBHOOK_URL (없으면 같은 디렉토리 기준 ../.env 에서 로드 시도)
# URL이 비어 있으면 경고만 출력하고 정상 종료(빌드/작업을 깨지 않음).

set -euo pipefail

STATUS="info"
TITLE=""
TEXT=""
FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --status) STATUS="${2:-info}"; shift 2 ;;
    --title)  TITLE="${2:-}";       shift 2 ;;
    --text)   TEXT="${2:-}";        shift 2 ;;
    --file)   FILE="${2:-}";        shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "알 수 없는 옵션: $1" >&2; exit 2 ;;
  esac
done

# ── 웹훅 URL 확보 ───────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEBHOOK="${CLAUDE_DEV_SLACK_WEBHOOK_URL:-}"
if [[ -z "$WEBHOOK" && -f "$SCRIPT_DIR/../.env" ]]; then
  WEBHOOK="$(grep -E '^CLAUDE_DEV_SLACK_WEBHOOK_URL=' "$SCRIPT_DIR/../.env" | tail -1 | cut -d= -f2- | tr -d '"' || true)"
fi

if [[ -z "$WEBHOOK" ]]; then
  echo "[notify-slack] CLAUDE_DEV_SLACK_WEBHOOK_URL 가 설정되지 않아 Slack 보고를 건너뜁니다." >&2
  echo "[notify-slack]  → .env 에 CLAUDE_DEV_SLACK_WEBHOOK_URL=https://hooks.slack.com/... 를 추가하세요." >&2
  exit 0
fi

# ── 본문 확보 (파일 > --text > stdin) ───────────────────────────
if [[ -n "$FILE" ]]; then
  if [[ ! -f "$FILE" ]]; then echo "[notify-slack] 파일 없음: $FILE" >&2; exit 1; fi
  TEXT="$(cat "$FILE")"
elif [[ -z "$TEXT" && ! -t 0 ]]; then
  TEXT="$(cat)"
fi

# ── 상태별 이모지 ───────────────────────────────────────────────
case "$STATUS" in
  success) EMOJI="✅" ;;
  failure) EMOJI="❌" ;;
  *)       EMOJI="ℹ️" ;;
esac

HEADER="$EMOJI ${TITLE:-antcamp 작업 보고}"

# ── JSON 안전 생성 (jq > python3 > 미설치 시 단순 이스케이프) ────
build_payload() {
  local header="$1" body="$2"
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg h "$header" --arg b "$body" \
      '{text: ($h + "\n" + $b),
        blocks: [
          {type:"section", text:{type:"mrkdwn", text:("*" + $h + "*")}},
          {type:"section", text:{type:"mrkdwn", text:$b}}
        ]}'
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$header" "$body" <<'PY'
import json, sys
h, b = sys.argv[1], sys.argv[2]
print(json.dumps({
    "text": f"{h}\n{b}",
    "blocks": [
        {"type": "section", "text": {"type": "mrkdwn", "text": f"*{h}*"}},
        {"type": "section", "text": {"type": "mrkdwn", "text": b}},
    ],
}, ensure_ascii=False))
PY
  else
    # 최소 이스케이프 (jq/python3 없을 때)
    local esc
    esc="$(printf '%s' "$header"$'\n'"$body" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk 'BEGIN{ORS="\\n"}{print}')"
    printf '{"text":"%s"}' "$esc"
  fi
}

PAYLOAD="$(build_payload "$HEADER" "$TEXT")"

# ── 전송 ────────────────────────────────────────────────────────
HTTP_CODE="$(curl -sS -o /dev/null -w '%{http_code}' \
  -X POST -H 'Content-Type: application/json' \
  --data "$PAYLOAD" "$WEBHOOK" || echo "000")"

if [[ "$HTTP_CODE" == "200" ]]; then
  echo "[notify-slack] 보고 완료 (${STATUS})."
else
  echo "[notify-slack] 전송 실패 (HTTP $HTTP_CODE)." >&2
  exit 1
fi
