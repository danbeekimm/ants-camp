---
name: revref
description: antcamp 코드 품질·아키텍처 점검 및 리팩토링 제안. 지정 파일 또는 이번 세션 변경분(git diff)을 docs/coding-conventions.md 기준으로 리뷰한다. 새 Controller/Service/Port/Adapter/Entity/Repository/Feign/Kafka 생성, 메서드 추가, 50줄 이상 수정, common/ 변경 후 사용.
argument-hint: "[파일경로...] | --context"
---

# revref

antcamp MSA의 코드 품질·아키텍처 점검 skill. 기준은 `docs/coding-conventions.md`(= `.coderabbit.yaml` 원칙)이며, 위반을 심각도별로 분류해 보고한다.

## 동작 절차

### 1. 대상 파일 식별
- **파일 경로가 주어지면** 해당 파일을 대상으로 한다.
- **`--context` 플래그면** `git diff --name-only HEAD` + `git status --porcelain`로 이번 세션 변경/생성 파일을 추출한다. (스테이징 전 파일 포함)
- **디렉토리가 주어지면** 그 하위 `*.java` 파일을 대상으로 한다.
- `*.md`, `*.yaml/yml`, 생성물(`build/`, `generated/`)은 대상에서 제외한다.

대상이 없으면 사용자에게 알리고 종료한다.

### 2. 병렬 리뷰 에이전트 실행
대상 파일을 컨텍스트로 주고, 아래 차원별로 `general-purpose` 에이전트를 **병렬 실행**한다. 각 에이전트는 `docs/coding-conventions.md`의 해당 섹션을 기준으로 위반·개선점을 찾고, `파일:라인` + 심각도(🔴/🟡) + 근거 + 제안을 반환한다.

- **아키텍처/레이어/DDD** (conventions §2,5,7): domain→infra 역참조, presentation→domain 직접 접근, application 우회, 트랜잭션 경계(1 트랜잭션 1 Aggregate), 분산 트랜잭션 시도, MSA 책임 경계 침범, 포트/어댑터 배치.
- **Spring/JPA 내부** (conventions §1): `@Transactional` 과대 범위(특히 외부 API 호출 포함), 엔티티 `@Setter`/`@Data`, N+1/`FetchType.EAGER`.
- **동시성** (conventions §6): 경쟁 조건 락 누락, Redis를 source of truth로 사용, 수량/재고 감소에 Lua/분산락 부재.
- **타입 안정성/공통 모듈** (conventions §4,9): VO/DTO/Event의 `record` 사용, primitive obsession, compact constructor 검증(내부 이벤트 record는 예외), `CommonResponse`/`ErrorCode`/`BusinessException`/`GlobalExceptionHandler`/`BaseEntity`+`@SuperBuilder` 재사용.

### 3. 보조 skill 활용
- `--context` 모드(=diff 리뷰)일 때는 `/code-review`(정확성 버그)와 `/security-review`(보안·민감정보 로그, conventions §8)도 함께 돌려 결과를 통합한다.
- 특정 파일 모드에서는 보안 민감 코드(인증/토큰/외부키/로그)가 포함된 경우에만 `/security-review`를 추가한다.

### 4. 종합 보고
중복을 제거하고 심각도순으로 정리해 보고한다.

```
## revref 결과 — <대상 요약>

### 🔴 Request Changes (반드시 수정) — 아키텍처/DDD/트랜잭션/이벤트 위반
- [파일:라인] 문제 — 근거(conventions §N) → 제안

### 🟡 Comment (개선 권장) — 성능/품질/리팩토링
- [파일:라인] 문제 → 제안

### ✅ 양호
- 잘 지켜진 규약 요약
```

수정까지 요청받았다면(`--fix` 등) 🔴 항목부터 적용하고, 적용 후 다시 빌드로 검증한다.

## 예시
```
/revref --context
/revref apps/trade-service/src/main/java/io/antcamp/tradeservice/presentation/TradeController.java
/revref apps/asset-service/src/main/java/io/antcamp/assetservice/
```

## 참고
- 코딩 규칙 원문: `docs/coding-conventions.md`
- 패키지/네이밍 규약: 루트 `CLAUDE.md`
- 자동 실행 조건: `docs/automation-workflow.md` (A. 코드 작업 후 자동 검토)
