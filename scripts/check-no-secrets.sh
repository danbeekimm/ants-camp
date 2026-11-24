#!/usr/bin/env bash
# 사용: scripts/check-no-secrets.sh <폴더>
# 폴더 안에 마스킹되지 않은 토큰 · 비밀번호 · 키 값이 남아 있으면 파일과 줄 번호를 출력하고 종료 코드 1.
# 값 자체는 출력하지 않는다 (검사 결과가 다시 시크릿을 퍼뜨리지 않게).
set -uo pipefail

dir="${1:?사용: scripts/check-no-secrets.sh <폴더>}"
[ -d "$dir" ] || { echo "폴더가 없다: $dir" >&2; exit 1; }
# shellcheck source=scripts/secret-patterns.sh
. "$(dirname "$0")/secret-patterns.sh"

found=0
report() { # $1=종류 $2=패턴
  local hits
  hits="$(grep -rInE -- "$2" "$dir" | cut -d: -f1,2 || true)"
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits" | sed "s/^/[$1] /"
    found=1
  fi
}
report "JWT"        "$PAT_JWT"
report "인증 헤더"   "$PAT_BEARER"
report "본문 토큰"   "$PAT_JSON"
report "환경 변수"   "$PAT_ENV"

if [ "$found" -ne 0 ]; then
  echo "실패: 마스킹되지 않은 값이 남아 있다. scripts/mask-secrets.sh $dir 를 실행한 뒤 다시 검사한다." >&2
  exit 1
fi
echo "통과: 시크릿 패턴 없음 ($dir)"
