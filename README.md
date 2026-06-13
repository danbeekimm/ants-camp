# AntCamp (antcamp)

> 모의투자 대회 플랫폼 + AIOps · LLM/RAG 어시스턴트를 갖춘 Spring Boot 기반 MSA

AntCamp는 사용자가 가상 자금으로 실시간 시세에 기반해 주식을 거래하고, 대회에 참여해 순위를 겨루는 **모의투자 대회 플랫폼**입니다. 여기에 더해 두 개의 AI 서비스 — **RAG 챗봇/평가 어시스턴트**와 **LLM 기반 AIOps 장애 대응 시스템** — 을 운영 인프라에 통합한 것이 특징입니다.

- **언어/런타임**: Java 17
- **프레임워크**: Spring Boot 3.5.13, Spring Cloud 2025.0.1
- **빌드**: Gradle 멀티모듈 (`io.antcamp`)
- **아키텍처**: MSA (Eureka 디스커버리 + Config Server + API Gateway), 도메인 서비스는 DDD/헥사고날

---

## 목차

- [시스템 아키텍처](#시스템-아키텍처)
- [서비스 카탈로그](#서비스-카탈로그)
- [기술 스택](#기술-스택)
- [디렉토리 구조](#디렉토리-구조)
- [로컬 실행](#로컬-실행)
- [배포 (CI/CD)](#배포-cicd)
- [관측성 & AIOps](#관측성--aiops)
- [참고 문서](#참고-문서)

---

## 시스템 아키텍처

```
                                   ┌──────────────┐
            Client ────────────────▶  API Gateway  │ :8080  (JWT 검증 → X-User-Id/X-Role 주입)
                                   └──────┬───────┘
        ┌──────────┬──────────┬──────────┼──────────┬──────────────┬───────────────┐
        ▼          ▼          ▼          ▼          ▼              ▼               │
   user-svc   trade-svc   asset-svc  competition  ranking-svc  assistant-svc       │
    :8082       :8084       :8086     -svc :8092    :8094         :8096             │
   인증/JWT   주문/실시간   계좌/자산   대회 관리    순위 계산    LLM+RAG 챗봇/평가     │
        │          │          │          │          │              │               │
        └────── Kafka 이벤트 버스 (대회/자산/순위 도메인 이벤트 비동기 연계) ──────────┘
                                                                                    │
   ┌────────────────────────────────────────────────────────────┐                 │
   │  notification-service :8098  (AIOps, 대부분 게이트웨이 우회)     │                 │
   │   • /prometheus   ◀── Alertmanager 직접 호출 (Bearer 인증)     │                 │
   │   • /interactions ◀── Slack 버튼 직접 호출 (HMAC 서명)         │                 │
   │   • /admin/**     ◀── 운영자 조회는 게이트웨이 경유 ────────────────────────────────┘
   └────────────────────────────────────────────────────────────┘

  공통 인프라:  Eureka :8761 · Config Server :8888 · PostgreSQL(pgvector) :5432 · Redis :6379 · Kafka :9092
  관측성:       Prometheus :9090 · Grafana :3000 · Loki :3100 · Alertmanager :9093 · Zipkin :9411
```

- **서비스 디스커버리**: 모든 서비스가 Eureka에 등록되며, Gateway와 서비스 간 호출은 Eureka 기반 로드밸런싱으로 라우팅됩니다. (게이트웨이의 실제 라우트 정의는 외부 config-server Git 저장소에서 관리되어 이 레포에는 포함되지 않습니다.)
- **중앙 설정**: 각 서비스는 Config Server(Git 백엔드)에서 환경별 설정을 로드합니다.
- **인증 (게이트웨이 경유 트래픽)**: API Gateway가 JWT를 검증(`GatewaySecurityConfig`)하고 `role` 클레임을 권한으로 변환한 뒤, 하위 서비스로 `X-User-Id`/`X-Role` 헤더를 전달합니다. 하위 서비스는 게이트웨이를 신뢰하고 이 헤더를 사용합니다.
  - **assistant-service는 이 경로를 따릅니다** — `ChatController` 등이 `X-User-Id`/`X-Role`을 필수 헤더로 받고 `PlayerRoleGuard`로 역할을 검사하므로, 게이트웨이가 주입하지 않으면 호출이 성립하지 않습니다.
- **게이트웨이 우회 (notification-service)**: 외부에서 직접 호출되는 두 엔드포인트는 게이트웨이를 거치지 않고 자체 인증을 갖습니다.
  - `/prometheus` (Alertmanager 웹훅): `Authorization: Bearer <webhook.secret>` 검증. 단, `webhook.secret`이 비어 있으면 검증을 건너뛰므로 운영 환경에서는 시크릿 주입이 필수입니다.
  - `/interactions` (Slack 버튼): `SlackSignatureVerificationFilter`(서블릿 필터)가 HMAC 서명을 검증하며, Slack의 3초 응답 제한을 맞추기 위해 컨트롤러는 즉시 200을 반환하고 액션은 비동기로 실행합니다.
  - `/admin/**` (운영자 조회): 게이트웨이를 경유하며 권한 체크(`hasAnyRole("ADMIN","MANAGER")`)도 게이트웨이에서 수행됩니다 — 컨트롤러는 전달받은 `X-User-Id`/`X-Role`을 로깅만 합니다.
- **비동기 연계**: 대회 등록/종료, 자산 평가, 순위 갱신 등은 Kafka 도메인 이벤트로 느슨하게 결합됩니다.

---

## 서비스 카탈로그

| 서비스 | 포트 | 책임 | 핵심 기술 |
|---|---|---|---|
| **api-gateway** | 8080 | 진입점. JWT 검증, 공개 경로 분기, 라우팅/로드밸런싱 | Spring Cloud Gateway(WebFlux), Security OAuth2 Resource Server |
| **user-service** | 8082 | 회원가입/로그인/토큰 재발급·로그아웃, 사용자 조회 | JWT(jjwt), Redis(refresh token), PostgreSQL |
| **trade-service** | 8084 | 시장가/지정가 주문, 미체결 자동 체결, 실시간 시세/호가 | KIS(한국투자증권) WebSocket·REST(Feign), STOMP, Redis, Elasticsearch, Kafka |
| **asset-service** | 8086 | 계좌/입출금, 보유 종목, 자산 평가 (대회 이벤트 구독) | Kafka Consumer, Feign(시세 조회), Redis, PostgreSQL |
| **competition-service** | 8092 | 대회 생성·공개·시작·종료·취소 라이프사이클, 참가자 관리 | DDD 도메인 이벤트(Kafka), PostgreSQL |
| **ranking-service** | 8094 | 실시간 순위 계산·조회, 종료 후 최종 순위 확정 | Kafka(자산 이벤트 수신), Redis 캐시, PostgreSQL |
| **assistant-service** | 8096 | LLM+RAG 챗봇, 문서 관리, LLM-as-judge 평가/Pairwise 비교, 프롬프트 버전 관리 | Spring AI, OpenAI/Anthropic/Gemini, pgvector, QueryDSL, Zipkin |
| **notification-service** | 8098 | AIOps: Prometheus 알림 → LLM 분석 → Slack 발송 → 운영자 액션(restart/rollback/cache) | Anthropic(Claude), Slack API, docker-java, Prometheus/Loki, Redis(dedup) |
| **eureka-server** | 8761 | 서비스 레지스트리 & 디스커버리 | Spring Cloud Netflix Eureka |
| **config-server** | 8888 | 중앙 설정 관리 (Git 백엔드) | Spring Cloud Config |

도메인 서비스(`user/trade/asset/competition/ranking`)는 **DDD + 헥사고날** 패턴(presentation → application → domain → infrastructure)을 따르며, `assistant`/`notification`은 명시적 port/adapter 구조로 외부 의존성(LLM, Slack, Docker, Prometheus 등)을 추상화합니다.

### common 모듈

전 서비스가 공유하는 라이브러리(`bootJar` 비활성, `jar`만 생성):

- `BaseEntity` — JPA Auditing(`createdAt/By`, `updatedAt/By`) + 소프트 삭제(`deletedAt/By`)
- `CommonResponse<T>` — 전사 통일 API 응답 포맷
- `ErrorCode` / `BusinessException` / `GlobalExceptionHandler` — 통합 에러 처리

---

## 기술 스택

| 구분 | 사용 기술 |
|---|---|
| **Core** | Java 17, Spring Boot 3.5.13, Spring Cloud 2025.0.1 |
| **MSA** | Eureka, Spring Cloud Config, Spring Cloud Gateway, OpenFeign, Resilience4j |
| **데이터** | PostgreSQL 17 (pgvector), Redis 7, Spring Data JPA, QueryDSL |
| **메시징** | Apache Kafka (KRaft), Zookeeper |
| **실시간** | WebSocket / STOMP, KIS 한국투자증권 WebSocket·REST |
| **AI/LLM** | Spring AI, OpenAI, Anthropic Claude, Google Gemini, pgvector RAG |
| **관측성** | Micrometer + Prometheus, Grafana, Loki + Promtail, Alertmanager, Zipkin |
| **인프라/운영** | Docker / Docker Compose, OCI 단일 인스턴스(Ubuntu aarch64 · Ampere A1), GitHub Actions(CI/CD), GHCR(컨테이너 레지스트리), nginx + Cloudflare(TLS 종단), docker-java |
| **테스트/부하** | JUnit 5, JMeter |

---

## 디렉토리 구조

```
.
├── apps/                     # 마이크로서비스 (각각 독립 Spring Boot 앱)
│   ├── api-gateway/
│   ├── user-service/
│   ├── trade-service/        # frontend/ 정적 테스트 UI 포함
│   ├── asset-service/
│   ├── competition-service/
│   ├── ranking-service/
│   ├── assistant-service/
│   ├── notification-service/
│   ├── eureka-server/
│   └── config-server/
├── common/                   # 공유 모듈 (BaseEntity, CommonResponse, ErrorCode 등)
├── monitoring/               # Prometheus / Grafana / Loki / Promtail / Alertmanager 설정
├── scripts/                  # oci-setup.sh(인스턴스 부트스트랩), nginx/ 리버스 프록시 예시
├── script/                   # init.sql(DB 초기화), seed-documents.sh(RAG 시드)
├── diagrams/                 # 아키텍처/RAG/평가/AIOps 다이어그램(PNG, Mermaid 원본)
├── jmeter-test/              # trade-service 부하 테스트 (.jmx + users.csv)
├── docker-compose.yml        # 로컬 전체 스택 구동 (개발용)
├── docker-compose.lite.yml   # OCI 단일 인스턴스 배포용 (경량 스택, GHCR 이미지 pull)
├── deploy.sh                 # 인스턴스 운영 헬퍼 (deploy/build/logs/ps/restart/down)
├── .env.example              # 환경변수 템플릿 (IMAGE_TAG 포함)
├── DEPLOY.md                 # 배포 운영 가이드 (OCI 단일 인스턴스)
├── docs/                     # 배포 전환 진행/잔여 작업 기록 (DEPLOY_PROGRESS / DEPLOY_TODO)
├── build.gradle / settings.gradle
└── *.md                      # 아키텍처 상세 문서 (아래 '참고 문서' 참조)
```

---

## 로컬 실행

### 사전 요구사항

- JDK 17
- Docker / Docker Compose
- 외부 연동 키 (선택): OpenAI / Anthropic / Gemini API Key, KIS(한국투자증권) App Key, Slack 토큰

### 1) 환경변수 준비

```bash
cp .env.example .env
# .env 파일을 열어 DB 자격증명, 포트, API 키, JWT 시크릿 등을 채운다.
```

`.env`는 포트(`*_SERVER_PORT`), DB 스키마(`*_SCHEMA`), Redis/Kafka 설정, LLM/외부 API 키, JWT 시크릿, Slack 설정을 정의합니다.

### 2) 빌드

```bash
# Windows
.\gradlew.bat clean build -x test

# macOS / Linux
./gradlew clean build -x test
```

### 3) 전체 스택 구동 (Docker Compose)

```bash
docker compose up -d --build
```

`docker-compose.yml`은 인프라(PostgreSQL+pgvector, Redis, Kafka, Zookeeper), 관측성(Prometheus, Grafana, Loki, Promtail, Alertmanager, Zipkin), 그리고 모든 애플리케이션 서비스를 기동합니다. 일부 서비스(`user-service` 등)는 `prod` 프로필로 묶여 있어 필요 시 `--profile prod`로 활성화합니다.

기동 순서는 헬스체크 기반 `depends_on`으로 제어됩니다 (Postgres/Kafka/Eureka/Config 정상화 후 도메인 서비스 시작).

### 4) 접속 포인트

| 대상 | URL |
|---|---|
| API Gateway | http://localhost:8080 |
| Eureka 대시보드 | http://localhost:8761 |
| Grafana | http://localhost:3000 |
| Prometheus | http://localhost:9090 |
| Kafka UI | http://localhost:8080 *(env 포트 참조)* |
| Zipkin | http://localhost:9411 |

> 실제 노출 포트는 `.env`의 값으로 결정됩니다. HTTP 시나리오는 루트의 `scenario*.http`, `http-client.env.json`을 참고하세요.

---

## 배포 (CI/CD)

> **2026-06 인프라 전환**: 기존 **AWS 멀티 EC2**(5대 역할 분리 · Aurora · ECR · CodeDeploy/SSM · Terraform IaC) 구성에서
> **OCI 단일 인스턴스**(Ubuntu aarch64 · Ampere A1, 4vCPU/24GB) + **GitHub Actions → GHCR → SSH** 파이프라인으로 이전했습니다.
> 운영 상세는 [`DEPLOY.md`](DEPLOY.md), 전환 기록은 [`docs/DEPLOY_PROGRESS.md`](docs/DEPLOY_PROGRESS.md)를 참고하세요.

### 배포 토폴로지

```
GitHub (dev push)
  └─ Actions (cd.yml)
       ├─ detect : 변경 서비스 감지 (common/compose/루트 gradle 변경 → 전체)
       ├─ build  : ubuntu-24.04-arm 러너에서 linux/arm64 이미지 빌드 → GHCR push
       └─ deploy : SSH(appleboy/ssh-action) → git 동기화 → docker compose pull + up -d
                        │
                   OCI 단일 인스턴스  (docker-compose.lite.yml 한 파일로 전체 스택)
                        └─ 호스트 nginx(80/443) ──TLS 종단── Cloudflare
                              · api.…  → 127.0.0.1:8080 (gateway)
                              · watch.… → 127.0.0.1:3000 (grafana)
                              · 모든 컨테이너 포트는 127.0.0.1 바인딩 (외부 직노출 없음)
```

- **빌드는 GitHub ARM 러너**가 전담 → 인스턴스는 이미지 `pull`만 (4vCPU 박스에서 빌드 부하 제거)
- 이미지: `ghcr.io/danbeekimm/<service>:latest` (+ `:<commit-sha>`)
- 단일 박스 메모리 예산(24GB): JVM 힙 합계 ~3.3GB(서비스별 `-Xmx` 256~512m), 실측 RSS ≈ 9GB(유휴)/11~12GB(부하)

### CI/CD (GitHub Actions, `.github/workflows/`)

- **ci.yml** — `dev` 대상 PR에서 `./gradlew build -x test` 수행 (빌드 검증, 테스트 미실행)
- **cd.yml** — `dev` push 시:
  1. **detect** — 변경된 `apps/<service>/` 감지 (`common/`·루트 Gradle·`docker-compose.lite.yml`·`cd.yml` 변경 시 **전체** 빌드)
  2. **build** — `ubuntu-24.04-arm` 러너에서 서비스별 멀티스테이지 Dockerfile로 `linux/arm64` 이미지 빌드 → **GHCR 푸시** (GHA 캐시 사용)
  3. **deploy** — SSH 접속 → `git reset --hard origin/dev` → `docker compose -f docker-compose.lite.yml pull && up -d`
  - 수동 실행(`workflow_dispatch`): `deploy_all=true` → 전체 빌드 후 배포 / `false` → 빌드 없이 현재 GHCR 이미지로 재배포(pull+up)만

**필요한 GitHub Secrets**: `OCI_HOST`, `OCI_USER`, `OCI_SSH_KEY`, `OCI_APP_DIR`, `OCI_PORT`(선택). GHCR push/pull은 워크플로 기본 `GITHUB_TOKEN`으로 처리됩니다.

### 인스턴스 운영 (`deploy.sh`)

인스턴스에서 수동 운영·디버깅·폴백 빌드에 사용합니다 (평상시 배포는 Actions가 담당).

| 명령 | 동작 |
|---|---|
| `./deploy.sh deploy` | GHCR 최신 이미지 pull + 기동 (수동 배포) |
| `./deploy.sh build [svc]` | 인스턴스에서 직접 빌드 (레지스트리 없이 폴백) |
| `./deploy.sh logs [svc]` / `ps` / `restart [svc]` / `down` | 로그 / 상태 / 재시작 / 중지 |

최초 셋업은 `scripts/oci-setup.sh`(docker·swap·방화벽)와 `scripts/nginx/antcamp.conf.example`(리버스 프록시)로 부트스트랩합니다.

---

## 관측성 & AIOps

- **메트릭**: 각 서비스가 `/actuator/prometheus`로 노출 → Prometheus가 15초 주기 스크랩 → Grafana 시각화
- **로그**: Promtail이 Docker 컨테이너 로그 수집 → Loki 저장 → Grafana 조회
- **트레이싱**: Zipkin 분산 트레이싱
- **알림(AIOps)**: Prometheus alert-rules → Alertmanager →
  - 정규 경로: `notification-service` 웹훅 → **LLM(Claude) 장애 분석** → Slack 메시지(원인/권장 조치/예상 복구 시간) + **원클릭 액션 버튼**
  - fallback: notification-service 자체 장애 시 Alertmanager가 Slack 직통 발송

운영자가 Slack 버튼을 클릭하면 **Human-in-the-Loop**로 ROLLBACK / RESTART / CACHE_CLEAR / FALSE_ALARM 액션이 실행됩니다. LLM은 *권장만*, 실제 실행 권한은 항상 사람의 클릭에 있습니다. 인프라 잡은 2단 방어(버튼 미노출 + 백엔드 차단)로 보호됩니다.

상세 설계는 [`aiops-architecture.md`](aiops-architecture.md)를 참고하세요.

---

## 참고 문서

| 문서 | 내용 |
|---|---|
| [DEPLOY.md](DEPLOY.md) | 배포 운영 가이드 (OCI 단일 인스턴스 셋업·Secrets·운영 명령) |
| [docs/DEPLOY_PROGRESS.md](docs/DEPLOY_PROGRESS.md) | AWS → OCI 배포 전환 작업 기록 |
| [docs/DEPLOY_TODO.md](docs/DEPLOY_TODO.md) | 배포 잔여 작업·운영 치트시트·트러블슈팅 |
| [aiops-architecture.md](aiops-architecture.md) | AIOps 파이프라인 (알림 → LLM 분석 → Slack HITL) 상세 |
| [rag-architecture.md](rag-architecture.md) | assistant-service RAG 아키텍처 |
| [rag-chunking-embedding.md](rag-chunking-embedding.md) | 문서 청킹/임베딩 전략 |
| [ASSISTANT_RAG_EVAL_REPORT.md](ASSISTANT_RAG_EVAL_REPORT.md) | RAG 응답 품질 평가(LLM-as-judge) 리포트 |
| [swagger-implementation-plan.md](swagger-implementation-plan.md) | API 문서화(Swagger) 계획 |
| `diagrams/` | 아키텍처·RAG·평가·AIOps 다이어그램 |

---

*Group: `io.antcamp` · Version: `0.0.1-SNAPSHOT`*
