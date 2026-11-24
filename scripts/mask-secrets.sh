#!/usr/bin/env bash
# 사용: scripts/mask-secrets.sh <폴더>
# 폴더 안 파일에서 토큰 · 비밀번호 · 키 값을 *** 로 바꾼다. 키 이름과 구조는 그대로 둔다.
set -euo pipefail

dir="${1:?사용: scripts/mask-secrets.sh <폴더>}"
[ -d "$dir" ] || { echo "폴더가 없다: $dir" >&2; exit 1; }
# shellcheck source=scripts/secret-patterns.sh
. "$(dirname "$0")/secret-patterns.sh"

find "$dir" -type f | while IFS= read -r f; do
  grep -Iq . "$f" || continue   # 빈 파일과 바이너리는 건너뛴다
  # JSON · 헤더 · 환경 변수 꼴을 먼저 바꾸고, 남은 JWT 를 마지막에 바꾼다.
  sed -E -i \
    -e "s/${PAT_JSON}/\1***/g" \
    -e "s/${PAT_BEARER}/\1***/g" \
    -e "s/${PAT_ENV}/\1***/g" \
    -e "s/${PAT_JWT}/***/g" \
    "$f"
done
echo "마스킹 완료: $dir"
