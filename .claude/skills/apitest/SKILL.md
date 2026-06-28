---
name: apitest
description: antcamp 빌드 → 단위 테스트 → API 실행 테스트를 수행하고 케이스·결과·request/response를 tests/에 저장한다. 엔드포인트/서비스 로직/이벤트 흐름 등 런타임 동작에 영향을 주는 변경 후 사용.
argument-hint: "[--service <name>] [--scenario <file.http>] [--no-slack]"
---

# apitest

antcamp의 빌드·테스트·API 실행 검증을 한 번에 수행하고 결과를 `tests/`에 보존하는 skill.

## 인자
- `--service <name>` — 대상 서비스(`trade`, `asset`, `competition`, `ranking`, `user`, `assistant`, `notification`). 생략 시 git diff로 영향 서비스를 추정한다.
- `--scenario <file.http>` — 실행할 시나리오 파일(루트 `scenario.http` / `scenario_all.http` / `scenario_trading.http`). 생략 시 대상 서비스에 맞는 시나리오를 선택한다.
- `--no-slack` — 종료 시 Slack 보고를 생략한다.

## 동작 절차

### 1. 빌드
```bash
./gradlew :apps:<service>:build -x test     # 대상 지정 시
./gradlew build -x test                      # 전체 / common 변경 시
```
실패하면 컴파일 오류를 요약하고 **여기서 중단**, 결과를 저장한 뒤 (가능하면) Slack 실패 보고.

### 2. 단위 테스트
```bash
./gradlew :apps:<service>:test               # 대상 지정 시
./gradlew test                               # 전체
```
실패 테스트는 클래스/메서드/원인을 요약한다.

### 3. 인프라 확인 / 기동
- 게이트웨이 헬스 확인: `curl -sf http://localhost:8080/actuator/health`
- 떠 있지 않으면: `.env` 존재 확인(`cp .env.example .env` 안내) 후 `docker compose up -d`, 그리고 `config-server`/`eureka-server`/게이트웨이/대상 서비스의 `/actuator/health`가 `UP`이 될 때까지 폴링(최대 ~120s).
- **인프라를 띄울 수 없으면**(Docker 미설치, `.env`/외부키 부재 등) 1~2단계 결과만 저장하고 그 사실을 `summary.md`에 명시한 뒤 종료한다. (빌드/테스트는 유효한 산출물이다.)

### 4. API 실행 테스트
- 호출은 **게이트웨이(`http://localhost:8080`)** 기준. 인증이 필요한 시나리오는 먼저 `/api/auth/login`으로 토큰을 받아 `Authorization: Bearer`로 호출한다(자격증명은 `http-client.env.json`의 `local` 환경 참조).
- 시나리오 실행 우선순위:
  1. `ijhttp`(JetBrains HTTP Client CLI) 또는 `httpyac`가 설치돼 있으면 `scenario*.http`를 직접 실행.
  2. 없으면 `.http` 시나리오의 각 단계를 `curl`로 변환해 순서대로 실행(요청 순서·변수 연결을 시나리오 주석에 맞춘다).
- 각 단계마다 HTTP 상태코드·응답 본문을 캡처하고, 시나리오에 기대값(예: `201 Created`)이 있으면 통과/실패를 판정한다.

### 5. 결과 저장 (`tests/`)
타임스탬프 디렉토리에 저장한다(레이아웃은 `tests/README.md`):
```bash
TS=$(date +%Y%m%d_%H%M%S)
mkdir -p "tests/results/$TS"
```
- `tests/results/<TS>/summary.md` — 환경, 빌드/단위테스트 결과, 시나리오 케이스별 통과/실패 표, 전체 합계.
- `tests/results/<TS>/<NN>_<name>.req.http` — 각 케이스의 요청(메서드/URL/헤더/바디). **토큰·시크릿은 마스킹**한다.
- `tests/results/<TS>/<NN>_<name>.res.json` — 각 케이스의 응답(상태코드 포함).

`summary.md` 표 예시:
```
| # | 케이스 | 메서드 | 엔드포인트 | 기대 | 실제 | 결과 |
|---|--------|--------|-----------|------|------|------|
| 01 | 대회 생성 | POST | /api/competitions | 201 | 201 | ✅ |
| 02 | 대회 게시 | PATCH | /api/competitions/{id}/publish | 200 | 500 | ❌ |
```

### 6. Slack 보고 (`--no-slack`가 아니면)
```bash
scripts/notify-slack.sh --status <success|failure> \
  --title "apitest: <대상>" \
  --file "tests/results/$TS/summary.md"
```
웹훅(`CLAUDE_DEV_SLACK_WEBHOOK_URL`) 미설정 시 스크립트가 경고만 내고 넘어간다(`docs/automation-workflow.md` C 참조).

## 보안 주의
- 저장물에 JWT/토큰/`KIS_*`/`*_API_KEY`/비밀번호가 평문으로 남지 않도록 마스킹한다.
- `tests/results/`는 커밋 대상이 아니다(`.gitignore` 처리). 케이스 정의/시나리오만 버전관리한다.

## 참고
- 시나리오: 루트 `scenario.http`, `scenario_all.http`, `scenario_trading.http`, 환경 `http-client.env.json`
- 결과 레이아웃: `tests/README.md`
- 자동 실행 조건/흐름: `docs/automation-workflow.md` (B)
