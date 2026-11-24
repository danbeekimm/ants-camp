#!/usr/bin/env bash
# mask-secrets.sh 와 check-no-secrets.sh 가 함께 쓰는 패턴. 한 곳에만 둔다.
# 각 패턴은 "값이 실제로 들어 있는 경우" 만 잡는다. 이미 *** 로 바뀐 값과 빈 값은 잡지 않는다.

# 1) JWT — eyJ 로 시작하고 점 두 개로 나뉜 긴 문자열
PAT_JWT='eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
# 2) 인증 헤더 — Authorization: Bearer <값>
PAT_BEARER='(Authorization: *Bearer +)[^ *"'"'"'][^ "'"'"']*'
# 3) 응답 본문의 토큰 · 비밀번호 — "accessToken": "<값>"
PAT_JSON='("(accessToken|refreshToken|access_token|refresh_token|password)" *: *")[^"*][^"]*'
# 4) 환경 변수 꼴 — KIS_*=<값>, *_API_KEY=<값>, *_SECRET=<값>, *_TOKEN=<값>, *_PASSWORD=<값>
PAT_ENV='((KIS_[A-Z0-9_]+|[A-Z0-9_]*(_API_KEY|_SECRET|_TOKEN|_PASSWORD)[A-Z0-9_]*)=)[^ *"'"'"'][^ "'"'"']*'
