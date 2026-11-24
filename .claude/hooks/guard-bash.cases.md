# guard-bash.sh 시험표

`guard-bash.sh` 는 AI가 셸 명령을 실행하기 **전에** 불려서, 위험한 명령이면 종료 코드 2 로 막는다.
아래는 가짜 입력을 넣어 직접 돌린 결과다. 훅을 고치면 이 표를 다시 돌린다.

## 손으로 돌리는 방법

```bash
printf '{"tool_input":{"command":"cat .env"}}' | bash .claude/hooks/guard-bash.sh
echo $?        # 2 = 차단, 0 = 통과
```

## 결과 (2026-11-24, Windows 11 · Git Bash · jq 로 입력 읽기)

| # | 명령 | 기대 | 결과 |
|---|---|---|---|
| 1 | `./gradlew build -x test` | 통과 | 통과 |
| 2 | `cat .env` | 차단 | 차단 |
| 3 | `grep KEY ./.env` | 차단 | 차단 |
| 4 | `source .env && ./gradlew bootRun` | 차단 | 차단 |
| 5 | `cat .env.example` | 통과 | 통과 |
| 6 | `./deploy.sh deploy` | 차단 | 차단 |
| 7 | `bash gh_prod_secret.sh` | 차단 | 차단 |
| 8 | `git push origin main` | 차단 | 차단 |
| 9 | `git push -f origin feature/x` | 차단 | 차단 |
| 10 | `git push origin feature/x` | 통과 | 통과 |
| 11 | `git push origin maintenance-fix` | 통과 | 통과 |
| 12 | `docker compose down -v` | 차단 | 차단 |
| 13 | `docker compose down` | 통과 | 통과 |
| 14 | `docker compose up -d` | 통과 | 통과 |
| 15 | `ls -la` | 통과 | 통과 |
| 16 | `Get-Content .env` (PowerShell) | 차단 | 차단 |
| 17 | `type .\.env` (Windows 경로) | 차단 | 차단 |
| 18 | `cat "$CLAUDE_PROJECT_DIR/.env"` | 차단 | 차단 |
| 19 | `cp .env.example .env.local.sample` | 통과 | 통과 |
| 20 | `grep -r dotenv build.gradle` | 통과 | 통과 |
| 21 | `git push origin HEAD:main` | 차단 | 차단 |
| 22 | `git log origin/main --oneline` | 통과 | 통과 |
| 23 | `docker compose -f docker-compose.lite.yml down --volumes` | 차단 | 차단 |

1~15 는 처음 정한 시험표, 16~23 은 Windows · PowerShell 환경과 경계 경우를 더한 것이다.

`jq` 와 `python3` 가 모두 없는 환경도 시험했다. 이때는 명령만 꺼내지 못하므로 입력 전체를 검사한다.
`cat .env` 는 차단, `ls -la` 는 통과로 같은 결과가 나왔다.

## 한계 — 알고 있는 우회 경로

이 훅은 명령 **문자열**을 보는 방식이다. 문자열에 `.env` 가 그대로 나타나지 않으면 지나간다.

| 명령 | 결과 | 왜 지나가는가 |
|---|---|---|
| `F=.en; cat ${F}v` | 통과 | 파일 이름을 변수로 조합했다 |
| `cat .e*v` | 통과 | 셸이 실행 시점에 이름을 펼친다 |

그래서 이 훅은 **실수를 막는 장치**이지 완전한 차단이 아니다.

- 파일 읽기 도구로 `.env` 를 여는 것은 `.claude/settings.json` 의 `deny` 규칙이 따로 막는다.
- 의도적인 우회까지 막으려면 격리된 실행 환경이 필요하다.
- 차단 메시지 끝에 "우회하지 말고 사용자에게 알린다" 를 붙여, 막힌 뒤의 행동도 함께 지시한다.

## 알아 둘 동작

- `cp .env.example .env` 도 차단된다. `.env` 를 만드는 일은 사람이 직접 한다.
- `Bash` 와 `PowerShell` 도구 양쪽에 연결되어 있다 (`settings.json` 의 `matcher`).
