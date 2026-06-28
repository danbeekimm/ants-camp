# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 프로젝트 개요

`antcamp` — 가상 주식 거래 경진대회 플랫폼. Spring Boot 3.5 / Java 17 기반의 **MSA 모노레포**다. 단일 Gradle 멀티 모듈 빌드 안에 인프라 서비스(Eureka, Config Server, Gateway)와 도메인 서비스 7개(user·trade·asset·competition·ranking·assistant·notification)가 함께 들어 있다. 그룹 ID는 `io.antcamp`.

## 빌드 · 테스트 · 실행

루트의 Gradle Wrapper(`./gradlew`)로 모든 작업을 수행한다. 루트 프로젝트는 `bootJar`가 꺼져 있어 실행 불가하며, 각 `apps:<service>`가 실행 가능한 Boot 모듈이다.

```bash
# 전체 빌드 (CI는 -x test 로 테스트 제외 빌드)
./gradlew build

# 특정 서비스만 빌드 / 실행
./gradlew :apps:user-service:build
./gradlew :apps:user-service:bootRun

# 전체 테스트 (JUnit 5 / useJUnitPlatform)
./gradlew test

# 특정 서비스 테스트
./gradlew :apps:trade-service:test

# 단일 테스트 클래스 / 메서드
./gradlew :apps:trade-service:test --tests "io.antcamp.tradeservice.SomeClassTest"
./gradlew :apps:trade-service:test --tests "*SomeClassTest.someMethod"
```

> `common` 모듈을 수정하면 그것에 의존하는 모든 서비스를 다시 빌드해야 한다(CD도 `common/` 변경 시 전 서비스를 배포 대상으로 잡는다).

### 로컬 인프라 기동

대부분의 서비스는 설정을 **Config Server에서 원격으로** 받아오므로(아래 참조), 단독 실행보다 Docker Compose로 띄우는 것을 전제로 한다.

```bash
cp .env.example .env        # 포트·DB·시크릿 등 값 채우기 (필수)
docker compose up -d        # 로컬 전체 스택 (docker-compose.yml: Postgres/Redis/Kafka/Zipkin/모니터링 포함)
docker compose down         # 전체 중지
```

`deploy.sh`는 로컬용이 아니라 **OCI 단일 인스턴스의 수동 운영 헬퍼**다(`docker-compose.lite.yml` 대상, 평상시 배포는 CD가 GHCR 이미지를 pull). 인스턴스에서 직접 쓸 때:

```bash
./deploy.sh deploy          # GHCR 최신 이미지 pull 후 기동 (수동 배포)
./deploy.sh build [svc]     # 인스턴스에서 직접 빌드 (레지스트리 없이 폴백)
./deploy.sh ps | logs [svc] | restart [svc] | down
```

Postgres 초기화는 `script/init.sql`이 담당한다 — 서비스별 **스키마**(`users`, `trade`, `asset`, `competition`, `ranking`, `assistant`, `notification`)와 pgvector/hstore/uuid-ossp 확장을 생성한다.

## 아키텍처

### 서비스 구성과 통신

외부 트래픽은 항상 **`api-gateway`(8080)** 를 거친다. 서비스는 Eureka로 서로를 발견하고, 서비스 간 호출은 OpenFeign 또는 (게이트웨이의 경우) 논블로킹 `WebClient`로 한다.

| 서비스 | 포트 | 핵심 역할 / 스택 |
|---|---|---|
| api-gateway | 8080 | WebFlux 게이트웨이, JWT 검증, 헤더 주입 |
| config-server | 8888 | Spring Cloud Config (외부 git 백엔드) |
| eureka-server | 8761 | 서비스 디스커버리 |
| user-service | 8082 | 회원/인증, JWT 발급, Redis |
| trade-service | 8084 | 주문/체결, WebSocket·KIS 외부 연동, Elasticsearch, Kafka, Resilience4j |
| asset-service | 8086 | 자산/포트폴리오, Kafka, Feign |
| competition-service | 8092 | 대회 도메인, Kafka |
| ranking-service | 8094 | 랭킹, Redis, Kafka |
| assistant-service | 8096 | RAG 챗봇 (Spring AI + pgvector), 평가 파이프라인 |
| notification-service | 8098 | AIOps 알림, Slack 연동, QueryDSL |

공유 인프라: **Postgres**(서비스별 스키마 분리), **Redis**, **Kafka**(서비스 간 이벤트), **Zipkin**(분산 트레이싱).

### 헥사고날 아키텍처 (도메인 서비스 공통 규약)

각 도메인 서비스는 패키지 `io.antcamp.<service>` 아래 4개 레이어로 나뉜다. **의존성 방향은 안쪽(domain)으로만 흐르며, domain은 인프라에 의존하지 않는다.**

```
presentation/    # @RestController, request/response DTO, Swagger docs
application/      # 유스케이스 서비스, port 인터페이스, command/query/result DTO
domain/          # 엔티티/모델, repository 인터페이스(포트), 도메인 예외 — POJO
infrastructure/  # 어댑터: JPA/persistence, Feign client, LLM, 스케줄러, 외부 연동
config/          # 스프링 @Configuration
```

- **포트는 안쪽(`application/port`, `domain/repository`)에 인터페이스로 정의**하고, 구현 어댑터는 `infrastructure`에 둔다. 예: `domain/repository/ChatSessionRepository`(포트) ↔ `infrastructure/persistence/adapter/ChatSessionRepositoryImpl`(어댑터). `application/port/VectorStorePort` ↔ `infrastructure/vector` 어댑터.
- 새 외부 연동을 추가할 때는 application/domain에 포트를 먼저 두고 infrastructure에서 구현하는 흐름을 따른다.

#### 패키지 구조 (실제 예시 — `assistant-service`)

레이어 안의 하위 패키지까지 포함한 표준 구조다. 모든 도메인 서비스가 이 형태를 (규모에 맞게) 따른다. 단순한 서비스(예: `user-service`)는 infrastructure 어댑터 없이 `application/service` + `domain`만 두기도 한다.

```
io.antcamp.<service>/
├── presentation/
│   ├── controller/            # @RestController (+ controller/docs/ : Swagger 인터페이스)
│   └── dto/
│       ├── request/           # 요청 DTO
│       └── response/          # 응답 DTO
├── application/
│   ├── service/               # 유스케이스 서비스(+ Processor 등)
│   ├── port/                  # 아웃바운드 포트 인터페이스 (LlmPort, VectorStorePort …)
│   └── dto/
│       ├── command/           # 쓰기 유스케이스 입력
│       ├── query/             # 읽기 유스케이스 입력
│       └── result/            # 유스케이스 출력
├── domain/
│   ├── model/                 # 도메인 엔티티/모델 (POJO)
│   ├── repository/            # 영속성 포트 인터페이스
│   └── exception/             # 도메인 예외
├── infrastructure/
│   ├── entity/                # JPA 엔티티 (BaseEntity 상속)
│   ├── persistence/
│   │   ├── jpa/               # Spring Data JPA 인터페이스
│   │   ├── adapter/           # repository 포트 구현(어댑터)
│   │   └── query/             # QueryDSL 등 동적 쿼리
│   ├── client/                # Feign / 외부 API 클라이언트
│   ├── messaging/kafka/       # producer / consumer
│   ├── llm/ · vector/ · scheduler/ · security/ · config/   # 외부 연동·인프라 설정
│   └── ...
└── config/                    # 스프링 @Configuration (Swagger, JPA Auditing 등)
```

> 일부 서비스는 JPA 엔티티/리포지토리를 `infrastructure/entity`, `infrastructure/repository`에 두는 더 평평한 변형을 쓴다(예: `trade-service`). 신규 서비스/코드는 위의 `persistence/{jpa,adapter,query}` 분리를 권장한다.

#### 네이밍 컨벤션 (구축된 코드 기반)

| 종류 | 패턴 | 위치 | 예시 |
|---|---|---|---|
| 컨트롤러 | `<도메인>Controller` | `presentation[/controller]` | `TradeController`, `ChatController`, `AuthController` |
| Swagger 문서 IF | `<컨트롤러>Docs` | `presentation/controller/docs` | `ChatControllerDocs`, `DocumentControllerDocs` |
| 요청 DTO | `<동작><도메인>Request` | `presentation/dto/request` | `BuyStockRequest`, `SendMessageRequest`, `CreateCompetitionRequest` |
| 응답 DTO | `<동작/도메인>Response` | `presentation/dto/response` | `BuyStockResponse`, `ChatMessageResponse`, `LoginResponse` |
| 유스케이스 서비스 | `<도메인>Service` / `<도메인>ApplicationService` | `application/service` | `TradeService`, `AuthService`, `ChatApplicationService` |
| 보조 처리기 | `<도메인>Processor` | `application/service` | `EvalProcessor`, `PairwiseProcessor` |
| Command/Query/Result | `<동작><도메인>Command` · `Get<도메인>Query` · `<도메인><관점>Result` | `application/dto/{command,query,result}` | `SendMessageCommand`, `GetEvalResultsQuery`, `DocumentDetailResult` |
| 아웃바운드 포트 | `<도메인>Port` | `application/port` | `LlmPort`, `VectorStorePort`, `ResponseCachePort` |
| 영속성 포트 | `<도메인>Repository` | `domain/repository` | `ChatSessionRepository`, `EvalRepository` |
| 포트 구현(어댑터) | `<도메인>RepositoryImpl` / `<도메인>PersistenceAdapter` / `<포트>Adapter` | `infrastructure/persistence/adapter` | `ChatPersistenceAdapter`, `ResponseCacheAdapter` |
| JPA 엔티티 | `<도메인>Entity` | `infrastructure/entity` | `TradeEntity`, `ChatSessionEntity` |
| Spring Data IF | `Jpa<도메인>Repository` (또는 `<도메인>JpaRepository`) | `infrastructure/persistence/jpa` | `JpaChatSessionRepository`, `TradeJpaRepository` |
| Feign 클라이언트 | `<대상>Client` | `infrastructure/client` | `KisClient`, `AssetClient`, `ClaudeApiClient` |
| Kafka 발행/구독/이벤트 | `<이벤트>Producer[Impl]` · `<이벤트>Consumer` · `<동작><도메인>Event` | `…/messaging/kafka` 또는 `application/event` | `TotalAssetEventProducer`, `CompetitionEventConsumer`, `CompetitionEndedEvent` |
| 설정 | `<관심사>Config` | `config` / `infrastructure/config` | `SwaggerConfig`, `OpenFeignConfig`, `QuerydslConfig` |
| 도메인 예외 | `<사유>Exception` | `domain/exception` | `SessionNotFoundException`, `DocumentNotFoundException` |

- 패키지명은 소문자, 클래스는 `UpperCamelCase`, 상수는 `UPPER_SNAKE_CASE`. 서비스 루트 패키지는 하이픈 없이 붙여 쓴다(`trade-service` → `io.antcamp.tradeservice`).
- 공통 모듈 클래스는 `io.antcamp` 접두사 없이 `common.*` 패키지에 있다(`common.dto.CommonResponse` 등).

### 게이트웨이 인증 흐름 (매우 중요)

도메인 서비스는 **JWT를 직접 검증하지 않는다.** 인증은 전적으로 게이트웨이(`CustomAuthFilter`)가 담당한다:

1. 게이트웨이가 클라이언트가 위조했을 수 있는 `X-User-Id`, `X-Role`, `X-User-Name`, `X-User-Email`, `X-User-Phone` 헤더를 **먼저 제거**한다.
2. `Bearer` 토큰을 디코드(`ReactiveJwtDecoder`)해 `subject`(userId)를 얻고, `user-service`의 `/internal/users/{userId}`로 사용자 상태(`ACTIVE`)를 확인한다.
3. 검증 후 위 헤더들을 **새로 주입**하고 `Authorization` 헤더는 제거한 뒤 하위 서비스로 전달한다.
4. `PUBLIC_PREFIXES`(`/api/auth/`, `/api/public/`, `/api/users/register`)는 인증을 건너뛴다.

→ 따라서 도메인 서비스는 `X-User-Id` / `X-Role` 헤더를 신뢰해 사용자를 식별한다. 이 헤더는 게이트웨이를 거친 요청에서만 신뢰 가능하다.

### 설정 외부화 (Config Server)

서비스의 `src/main/resources/application.yaml`은 **이름과 config import 한 줄만** 담는 최소 부트스트랩이다:

```yaml
spring:
  application: { name: <service> }
  config:
    import: optional:configserver:${CONFIG_SERVER_URL}
```

실제 설정(DB URL, 포트, 모델 파라미터 등)은 **외부 git 저장소** [`danbeekimm/ants-camp-config`](https://github.com/danbeekimm/ants-camp-config)의 `configs/{application}/` 경로에서 가져온다(기본 브랜치 `dev`). 즉 **이 레포에서 application.yaml을 찾지 말 것** — 런타임 설정 변경은 config 레포에서 한다. 시크릿/포트는 `.env`(`.env.example` 참조)로 주입된다.

### 공통 모듈 (`common`)

모든 도메인 서비스가 의존하는 `java-library`. 신규 코드는 여기 규약을 따라야 한다:

- **`CommonResponse<T>`** — 모든 API 응답 래퍼. `CommonResponse.ok(data)` / `created(...)` / `accepted(...)` / `error(ErrorCode)` 정적 팩토리로 `ResponseEntity`를 만든다(`status`, `code`, `message`, `data` 구조).
- **`ErrorCode`(enum) + `BusinessException`** — 비즈니스 오류는 `throw new BusinessException(ErrorCode.XXX)`로 던진다. 새 에러는 `ErrorCode`에 도메인별 그룹으로 추가한다.
- **`GlobalExceptionHandler`** (`@RestControllerAdvice`) — `BusinessException`, `@Valid` 실패, JSON 파싱 실패, 그 외 예외를 일괄 `CommonResponse.error(...)`로 변환한다. 서비스에서 별도 핸들러를 만들기보다 이 패턴을 재사용한다.
- **`BaseEntity`** — `@MappedSuperclass` + JPA Auditing. 생성/수정/삭제 감사 필드와 **소프트 삭제**(`softDelete()`, `deletedAt`/`isDeleted()`)를 제공한다. 엔티티는 이를 상속하고 `@SuperBuilder`를 쓴다.

## 코딩 컨벤션 · 자동화 워크플로우

신규/수정 코드는 아래 컨벤션을 따르며, 작업 단계에 맞춰 자동 워크플로우를 수행한다. 상세 규칙·절차는 별도 문서에 있고, 여기 요약과 트리거만 따른다.

| 문서 | 내용 |
|---|---|
| `docs/coding-conventions.md` | 코딩 규칙(`.coderabbit.yaml` 원칙): 트랜잭션 범위, JPA 캡슐화/N+1, DDD·레이어 경계, MSA 경계, VO/`record`, 동시성/분산락, 로깅·보안, 공통 모듈 재사용. 심각도 🔴(필수)/🟡(권장)로 구분. |
| `docs/automation-workflow.md` | 자동 검토(A)·빌드/테스트/API 테스트(B)·Slack 보고(C) 워크플로우의 트리거와 흐름. |

### 자동 워크플로우 (이 지침을 따른다)

- **A. 코드 작업 후 자동 검토 — `/revref`**
  새 파일 생성, 메서드/엔드포인트/이벤트 핸들러 추가, 50줄 이상 수정, `common/` 변경 중 하나라도 해당하면 작업 후 `/revref --context`로 `docs/coding-conventions.md` 준수 여부를 점검한다. 오타·주석·문서/설정만 변경, 10줄 미만 수정은 제외.

- **B. 빌드→테스트→API 테스트 — `/apitest`**
  엔드포인트/서비스 로직/이벤트 흐름 등 런타임 동작에 영향을 주는 변경을 마치면 `/apitest`로 `빌드 → 단위 테스트 → (Docker 인프라) → scenario*.http 실행`을 수행하고, 케이스·결과·request/response를 `tests/`에 저장한다. 인프라/외부키가 없으면 빌드+단위 테스트까지만 수행하고 그 사실을 결과에 남긴다.

- **C. 완료 후 Slack 보고 — `scripts/notify-slack.sh`**
  주요 작업(특히 `/apitest`) 종료 시 결과를 Slack Incoming Webhook으로 보고한다. URL은 `.env`의 `CLAUDE_DEV_SLACK_WEBHOOK_URL`(미설정 시 보고는 건너뛰고 작업은 정상 진행). 외부 전송이므로 처음에는 사용자에게 확인을 받는다.

## 배포 (CD)

> 2026-06 **AWS(ECR + 다중 EC2 + SSM) → OCI 단일 인스턴스**로 전환됨. 배경·구성은 `docs/DOWNSIZE-PLAN.md`, `docs/DEPLOY_PROGRESS.md` 참조.

`dev` 브랜치 push 시 `.github/workflows/cd.yml`이 동작한다. 흐름:

1. **변경 감지**(`dorny/paths-filter`) — `core`(= `common/`, 루트 `build.gradle`/`settings.gradle`/`gradle*`, `docker-compose.lite.yml`, `cd.yml`)가 바뀌면 **전 서비스** 빌드, 아니면 변경된 `apps/<service>`만 빌드.
2. **이미지 빌드** — `ubuntu-24.04-arm` 러너에서 서비스별 `apps/<service>/Dockerfile` 멀티 스테이지로 **linux/arm64** 빌드.
3. **레지스트리 푸시** — **GHCR**(`ghcr.io/<owner>/<service>:latest` + `:<sha>`).
4. **배포** — **SSH**(`appleboy/ssh-action`)로 OCI 인스턴스 접속 → `git reset --hard origin/dev` → `docker login ghcr.io` → `docker compose -f docker-compose.lite.yml pull && up -d --remove-orphans` → `docker compose ... ps`.

- 전 서비스를 **단일 OCI 인스턴스**에서 `docker-compose.lite.yml` 하나로 함께 띄운다(과거 EC2별 그룹 배포 표는 폐기).
- **수동 실행**(`workflow_dispatch`): `deploy_all=true`면 전체 강제 빌드+배포, `false`면 빌드 없이 현재 GHCR 이미지로 재배포(pull+up)만.
- 필요한 시크릿: `OCI_HOST` / `OCI_USER` / `OCI_SSH_KEY` / `OCI_PORT` / `OCI_APP_DIR` (GHCR 인증은 `GITHUB_TOKEN`).
- 인스턴스 초기 셋업·리버스 프록시: `scripts/oci-setup.sh`, `scripts/nginx/antcamp.conf.example`.

`ci.yml`은 **`dev` 대상 PR**에서 `./gradlew build -x test`만 수행한다(temurin 17, `--no-daemon`, 테스트 미실행).

## Git 워크플로

- 기본/통합 브랜치는 **`dev`**. feature 브랜치는 `dev` 기준으로 분기한다(PR 템플릿 체크리스트 참조).
- 커밋/PR 유형 접두사: `feat`, `fix`, `!hotfix`, `refactor`, `chore`, `docs`, `test` 등. PR은 `.github/PULL_REQUEST_TEMPLATE.md` 양식을 따른다.

## 참고 문서

심화 설계는 루트의 한국어 아키텍처 문서를 참조한다(다이어그램은 `diagrams/`):

- `rag-architecture.md`, `rag-chunking-embedding.md` — assistant-service의 RAG 인제스트/추론 파이프라인, pgvector, 청킹·임베딩.
- `aiops-architecture.md` — notification-service의 Prometheus → LLM 분석 → Slack HITL(사람 승인) 알림 흐름.
- `ASSISTANT_RAG_EVAL_REPORT.md`, `swagger-implementation-plan.md` — RAG 평가, API 문서화 계획.
- API 시나리오 테스트: `scenario*.http` (IntelliJ HTTP Client, env는 `http-client.env.json`).
- `docs/coding-conventions.md` — 코딩 컨벤션(상세). `docs/automation-workflow.md` — 자동 검토/테스트/Slack 보고 워크플로우(상세).
- 스킬: `.claude/skills/revref`(코드 검토), `.claude/skills/apitest`(빌드·테스트·API 실행). 보고 스크립트: `scripts/notify-slack.sh`.
