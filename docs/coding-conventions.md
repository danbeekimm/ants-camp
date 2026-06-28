# 코딩 컨벤션 (antcamp)

이 문서는 antcamp MSA에서 **신규/수정 코드가 지켜야 하는 코딩 규칙**이다. 원칙은 CI 코드 리뷰 봇 설정(`.coderabbit.yaml`)과 동일한 기준을 따르며, 리뷰에서 위반이 발견되면 변경을 요구한다. 패키지 구조·네이밍 규약은 루트 `CLAUDE.md`를, 자동 검토/테스트/보고 흐름은 `docs/automation-workflow.md`를 참조한다.

> **심각도 기준** (`.coderabbit.yaml`과 동일)
> - **🔴 Request Changes (반드시 수정)** — 아키텍처 위반: DDD/레이어/트랜잭션/이벤트 경계 위반.
> - **🟡 Comment (개선 권장)** — 성능, 코드 품질, 리팩토링.

---

## 1. Spring Boot & JPA 내부

- **`@Transactional` 범위를 최소화한다.** 트랜잭션 안에서 외부 API(Feign/WebClient/KIS 등)를 호출하지 않는다 — DB 커넥션을 오래 쥐는 원인이 된다. 외부 호출은 트랜잭션 밖에서 수행하고, 결과만 짧은 트랜잭션으로 반영한다. 🔴
- **JPA 엔티티에 `@Setter`/`@Data`를 붙이지 않는다.** 상태 변경은 비즈니스 의미가 담긴 메서드로 캡슐화한다(예: `order.confirm()`, `account.withdraw(amount)`). 🔴
- **N+1을 유발할 수 있는 매핑을 피한다.** 연관관계는 `FetchType.LAZY`를 기본으로 하고, 필요한 곳에서 fetch join / `@EntityGraph` / QueryDSL로 명시적으로 로딩한다. `FetchType.EAGER`를 새로 추가하지 않는다. 🟡

```java
// Bad — 엔티티에 무분별한 Setter, EAGER
@Entity @Data
public class OrderEntity extends BaseEntity {
    @ManyToOne(fetch = FetchType.EAGER) private AccountEntity account;
}

// Good — 캡슐화된 상태 변경, LAZY
@Entity @Getter
@NoArgsConstructor(access = AccessLevel.PROTECTED)
@SuperBuilder
public class OrderEntity extends BaseEntity {
    @ManyToOne(fetch = FetchType.LAZY) private AccountEntity account;

    public void confirm() {
        if (this.status != OrderStatus.PENDING) throw new BusinessException(ErrorCode.INVALID_ORDER_STATE);
        this.status = OrderStatus.CONFIRMED;
    }
}
```

---

## 2. 아키텍처 & DDD

- **domain → infrastructure 역방향 참조 금지.** domain 레이어(엔티티/모델·repository 포트·도메인 예외)는 JPA·외부 API·스프링 인프라에 의존하지 않는 POJO여야 한다. 🔴
- **분산 환경 동시성(Race Condition)을 설계로 막는다.** 동시 수정이 가능한 로직(주문 수량 차감, 좌석/한도, 참가자 수 등)에는 적절한 락(Redis 분산락 등) 또는 원자적 연산을 둔다. 🔴

---

## 3. MSA 경계

- **다른 서비스의 책임을 침범하지 않는다.** 한 서비스가 여러 도메인을 소유하려는 구조를 만들지 않는다. 다른 도메인의 데이터가 필요하면 OpenFeign(동기) 또는 Kafka 이벤트(비동기)로 가져온다. 🔴
- 서비스 간 직접 DB 접근(다른 스키마 조회) 금지. 각 서비스는 자신의 스키마만 소유한다.

---

## 4. VO / 타입 안정성

- **VO·DTO·Event는 `record`로 작성한다.** 🟡
- **Primitive Obsession을 피하고 Strong Type VO를 쓴다.** 의미 있는 값(금액, 종목코드, userId 등)은 `String`/`long` 남용 대신 전용 타입으로 표현한다. 🟡
- **`record`의 compact constructor에 검증을 넣는다.** 단, **서비스 간 내부 이벤트 메시지 `record`는 발행 측에서 검증되었다고 가정**하므로 예외로 둔다. 🟡

```java
// Good — record + compact constructor 검증
public record BuyStockRequest(String stockCode, long quantity) {
    public BuyStockRequest {
        if (stockCode == null || stockCode.isBlank()) throw new BusinessException(ErrorCode.INVALID_INPUT);
        if (quantity <= 0) throw new BusinessException(ErrorCode.INVALID_INPUT);
    }
}
```

---

## 5. 트랜잭션 경계

- **하나의 트랜잭션에서 하나의 Aggregate만 수정한다.** 여러 Aggregate를 한 트랜잭션에서 바꾸지 않는다. 🔴
- **분산 트랜잭션(2PC 등)을 시도하지 않는다.** 서비스 간 일관성은 Kafka 이벤트 기반의 최종적 일관성(eventual consistency)으로 맞춘다. 🔴

---

## 6. 동시성

- **동시성 제어 누락 금지.** 경쟁 조건이 있는 로직은 락/원자연산을 반드시 둔다. 🔴
- **Redis를 source of truth로 쓰지 않는다.** Redis는 캐시/락/랭킹 보조 용도이며, 진실의 원천은 RDB다. 🔴
- **재고/수량 감소는 Lua 스크립트 또는 분산락 없이 시도하지 않는다.** 🔴

---

## 7. 레이어드 아키텍처

- **presentation → domain 직접 접근 금지.** 컨트롤러는 application 레이어(유스케이스 서비스)만 호출한다. 🔴
- **application 레이어를 거치지 않은 비즈니스 로직 실행 금지.** 🔴
- 포트는 안쪽(`application/port`, `domain/repository`)에 인터페이스로 정의하고, 구현 어댑터는 `infrastructure`에 둔다(루트 `CLAUDE.md`의 헥사고날 규약 참조).

---

## 8. 로깅 & 보안

- **민감 정보를 로그로 출력하지 않는다.** 비밀번호, JWT/토큰, API 키(KIS/LLM), 개인정보(이메일·전화번호) 등을 평문 로그에 남기지 않는다. 🔴

---

## 9. 공통 모듈(`common`) 규약

신규 코드는 `common` 모듈의 공통 타입을 재사용한다(서비스마다 따로 만들지 않는다).

- **응답은 `CommonResponse<T>`로 감싼다.** `CommonResponse.ok(data)` / `ok(message, data)` / `created(message, data)` / `accepted(message, data)`로 `ResponseEntity`를 만든다(`status`, `code`, `message`, `data` 구조).
- **비즈니스 오류는 `throw new BusinessException(ErrorCode.XXX)`.** 새 오류는 `common/exception/ErrorCode`에 도메인별 그룹으로 추가한다. 서비스별 예외(`SessionNotFoundException` 등)는 도메인 의미를 위해 둘 수 있으나, 최종적으로 `ErrorCode`에 매핑되어야 한다.
- **예외 처리는 `GlobalExceptionHandler`(`@RestControllerAdvice`)에 위임한다.** 서비스마다 별도 핸들러를 만들지 않는다. 컨트롤러에서 try-catch로 응답을 직접 만들지 않는다.
- **엔티티는 `BaseEntity`를 상속하고 `@SuperBuilder`를 쓴다.** 생성/수정/삭제 감사 필드와 소프트 삭제(`softDelete(by)`, `isDeleted()`)를 제공한다. 물리 삭제 대신 소프트 삭제를 기본으로 한다.

```java
// Good — 컨트롤러는 CommonResponse로 응답, 오류는 BusinessException
@PostMapping("/api/trades/buy")
public ResponseEntity<CommonResponse<BuyStockResponse>> buy(
        @RequestHeader("X-User-Id") Long userId,
        @Valid @RequestBody BuyStockRequest request) {
    BuyStockResponse result = tradeService.buy(userId, request.toCommand());
    return CommonResponse.created("매수 주문이 접수되었습니다.", result);
}
```

> 사용자 식별은 게이트웨이가 주입한 `X-User-Id` / `X-Role` 헤더로 한다(JWT 직접 검증 금지 — 루트 `CLAUDE.md`의 게이트웨이 인증 흐름 참조).
