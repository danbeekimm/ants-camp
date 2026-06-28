# 자동화 워크플로우 (antcamp)

이 문서는 Claude Code가 antcamp에서 **작업 단계에 따라 자동으로 수행하는 워크플로우**를 정의한다. 강제 방식은 (settings.json 훅이 아니라) 이 문서와 `CLAUDE.md`의 지침을 Claude가 따르는 방식이다. 코딩 규칙 자체는 `docs/coding-conventions.md`를 참조한다.

워크플로우는 세 가지다:

| # | 워크플로우 | 트리거 | 수단 |
|---|---|---|---|
| A | 코드 작업 후 자동 검토 | 아래 "자동 검토 조건" 충족 시 | `/revref` skill |
| B | 빌드 → 테스트 → API 실행 테스트 | 사용자가 요청하거나, 런타임 동작에 영향을 주는 변경 완료 후 | `/apitest` skill |
| C | 완료 후 Slack 보고 | A/B 또는 주요 작업 완료 후 | `scripts/notify-slack.sh` |

---

## A. 코드 작업 후 자동 검토 (`/revref`)

코드 작업을 완료하면 `docs/coding-conventions.md` 준수 여부를 자동으로 점검한다.

### 자동 검토 조건 (다음 중 하나라도 해당하면 `/revref --context` 실행)
- 새 파일 생성 (Controller, Service, Port/Adapter, Entity, Repository, Feign Client, Kafka Producer/Consumer 등)
- 기존 파일에 메서드/엔드포인트/이벤트 핸들러 추가
- 50줄 이상의 코드 수정
- `common/` 모듈 변경 (영향 범위가 전 서비스이므로 항상 검토)

### 제외 (자동 검토하지 않음)
- 단순 오타·주석·포맷팅 수정
- 설정/문서 파일(`*.md`, `*.yaml`, `*.yml`)만 변경
- 10줄 미만의 사소한 수정

### 수동 실행
```
/revref <파일경로...>     # 지정 파일 리뷰
/revref --context         # 이번 세션에서 변경된 파일(git diff) 리뷰
/revref apps/trade-service/src/main/java/.../TradeController.java
```

검토 결과는 심각도(🔴 Request Changes / 🟡 Comment)로 분류해 보고한다. 자세한 점검 항목은 `.claude/skills/revref/SKILL.md` 참조.

---

## B. 빌드 → 테스트 → API 실행 테스트 (`/apitest`)

런타임 동작에 영향을 주는 변경(엔드포인트, 서비스 로직, 이벤트 흐름 등)을 마치면 다음 순서로 검증하고, **테스트 케이스·결과·request/response를 `tests/`에 저장**한다.

```
/apitest                       # 변경 영향 서비스 자동 판단 후 전체 흐름
/apitest --service trade       # 특정 서비스 대상
/apitest --scenario scenario_trading.http   # 특정 시나리오만
```

흐름 (자세한 절차는 `.claude/skills/apitest/SKILL.md`):
1. **빌드** — `./gradlew build -x test` (또는 영향 서비스만)
2. **단위 테스트** — `./gradlew test` (또는 `:apps:<svc>:test`)
3. **인프라 확인/기동** — `docker compose up -d` 후 게이트웨이/서비스 `/actuator/health` 확인
4. **API 실행 테스트** — 루트 `scenario*.http`를 게이트웨이(`localhost:8080`) 기준으로 실행
5. **결과 저장** — `tests/results/<timestamp>/`에 요약·request·response 기록 (`tests/README.md` 레이아웃 참조)

> ⚠️ API 실행 테스트는 Docker 인프라(Postgres/Redis/Kafka/Config/Eureka/Gateway)와 외부 키(KIS·LLM 등 `.env`)가 필요하다. 인프라가 없으면 빌드+단위 테스트까지만 수행하고 그 사실을 결과에 명시한다.

---

## C. 완료 후 Slack 보고 (`scripts/notify-slack.sh`)

주요 작업(A/B 포함)을 마치면 개발자에게 Slack으로 결과를 보고한다.

### 설정 (최초 1회)
1. Slack에서 **Incoming Webhook**을 만들고 URL을 발급받는다.
2. `.env`에 추가:
   ```
   CLAUDE_DEV_SLACK_WEBHOOK_URL=https://hooks.slack.com/services/XXX/YYY/ZZZ
   ```
   (`.env.example`에 키가 준비되어 있다.)

### 사용
```bash
# 성공 보고
scripts/notify-slack.sh --status success --title "trade-service 매수 API 추가" \
  --text "빌드/단위테스트 통과, API 시나리오 12/12 성공. 결과: tests/results/20260628_153000/"

# 실패 보고
scripts/notify-slack.sh --status failure --title "asset-service 빌드 실패" \
  --text "컴파일 오류 3건. 로그: build/reports/..."

# 본문을 파일/표준입력으로 전달
scripts/notify-slack.sh --status success --title "API 테스트 요약" --file tests/results/20260628_153000/summary.md
```

- `CLAUDE_DEV_SLACK_WEBHOOK_URL`이 비어 있으면 스크립트는 **경고만 출력하고 정상 종료**한다(빌드/작업을 깨지 않는다).
- 보고 호출 전에는 사용자에게 보고 대상/내용을 간단히 알리고, 외부 전송이므로 처음에는 확인을 받는다.

### 자동 보고 기준
- `/apitest` 종료 시: 성공/실패 요약을 자동 보고 (웹훅이 설정된 경우)
- 사용자가 명시적으로 "보고해줘"라고 하거나, 장시간 작업의 마무리 시점
- 사소한 변경(문서/오타)은 보고하지 않는다.
