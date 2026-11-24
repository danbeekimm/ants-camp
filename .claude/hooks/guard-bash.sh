#!/usr/bin/env bash
# 셸 명령 실행 전 검사 (PreToolUse 훅).
#   종료 코드 0 = 통과, 2 = 차단 (표준 오류에 쓴 글이 AI에게 전달된다)
# 한계: 명령 문자열을 보는 방식이라 실수를 막는 수준이다. 변수로 경로를 조합하면 지나간다.
#       시험표와 알려진 우회 경로는 guard-bash.cases.md 에 있다.

input="$(cat)"

# 표준 입력(JSON)에서 실행하려는 명령 문자열만 꺼낸다. jq 가 없으면 python3 로 읽는다.
cmd=""
if command -v jq >/dev/null 2>&1; then
  cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
fi
if [ -z "$cmd" ] && command -v python3 >/dev/null 2>&1; then
  cmd="$(printf '%s' "$input" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("command",""))' 2>/dev/null)"
fi
# 둘 다 없거나 읽지 못했으면 입력 전체를 검사한다. 못 읽었다고 그냥 통과시키지 않는다.
[ -z "$cmd" ] && cmd="$input"

deny() { echo "차단: $1 우회하지 말고 사용자에게 알린다." >&2; exit 2; }
has()  { printf '%s' "$cmd" | grep -Eq -- "$1"; }

has 'deploy\.sh|gh_prod_secret\.sh'                 && deny "배포·운영 시크릿 스크립트는 사람이 직접 실행한다."
has '(^|[ /\\"'"'"'=<])\.env($|[ ;|&"'"'"'>)\\])'   && deny ".env 는 읽거나 고치지 않는다. 키 이름은 .env.example 을 본다."
has 'git +push.*( -f| --force)'                     && deny "강제 푸시 금지."
has 'git +push.*[ :/](main|master)($|[ ;|&"])'      && deny "main 직접 푸시 금지. 브랜치와 PR 을 쓴다."
has 'docker +compose.* down.* (-v|--volumes)'       && deny "볼륨 삭제는 사람이 직접 실행한다."
exit 0
