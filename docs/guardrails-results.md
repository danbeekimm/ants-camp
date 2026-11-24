# 가드레일 시험 기록

가드레일을 "지침" 에서 "설정 · 훅 · 테스트" 로 옮기면서 직접 돌려 본 결과다. 재지 않은 값은 적지 않았다.

- 시험일: 2026-11-24
- 기준 커밋: `148fd52` (dev)
- 환경: Windows 11 · Git Bash · JDK 17 (Temurin) · Gradle 8.14.4 · ArchUnit 1.5.1

## 1. 실행 전 훅 (`.claude/hooks/guard-bash.sh`)

가짜 입력 23개를 넣어 기대와 결과가 모두 같았다 (차단 13 · 통과 10). 알려진 우회 경로 2개도 함께 적어 두었다.
표와 한계는 [`.claude/hooks/guard-bash.cases.md`](../.claude/hooks/guard-bash.cases.md).

**아직 하지 않은 것:** 실제 세션에서 `.env` 읽기를 시켰을 때 거절되는지, Slack 보고 스크립트 실행 때 확인을 묻는지는 사람이 새 세션에서 확인해야 한다.

## 2. 마스킹 검사 (`scripts/mask-secrets.sh` · `scripts/check-no-secrets.sh`)

가짜 토큰을 넣은 시험 파일 4개(요청 `.http`, 응답 `.json`, 환경 변수 꼴, 요약 `.md`)로 확인했다.

| 단계 | 결과 |
|---|---|
| 마스킹 전 검사 | 실패 (종료 코드 1) — 7곳을 `파일:줄` 로 출력, 값은 출력하지 않음 |
| 마스킹 | 값만 `***` 로 바뀌고 키 이름 · JSON 구조 · 다른 줄은 그대로 |
| 마스킹 후 검사 | 통과 (종료 코드 0) |
| 한 번 더 마스킹 후 검사 | 통과 (여러 번 돌려도 결과가 같다) |

값이 비어 있는 줄(`EMPTY_API_KEY=`)과 시크릿이 아닌 줄(`SERVER_PORT=8080`)은 건드리지 않았다.

## 3. 아키텍처 테스트 (`./gradlew archTest`)

도메인 서비스 7개에 같은 규칙 4개를 두었다 (`apps/<service>/src/archTest/`).

| 규칙 | 근거 조항 | 무엇을 보고 판정하는가 |
|---|---|---|
| 레이어 의존 방향 | §7 | 패키지 사이의 참조 |
| domain 은 바깥 레이어를 모른다 | §2 | domain 패키지에서 나가는 참조 |
| 엔티티에 공개 setter 금지 | §1 | `@Entity` 클래스의 `setXxx` 공개 메서드 |
| 예외 처리기는 common 에만 | §9 | `@RestControllerAdvice` · `@ControllerAdvice` 위치 |

### 도입 시점의 기존 위반 (얼려 둔 건수)

`FreezingArchRule` 이 기존 위반을 `apps/<service>/archunit_store/` 에 기록하고, 그 뒤로는 새 위반만 실패시킨다.
건수는 클래스 수가 아니라 **참조 한 건 한 건**(메서드 호출, 필드 타입 등)을 센 것이다.

| 서비스 | 레이어 의존 방향 | domain 역참조 | 엔티티 setter | 예외 처리기 위치 |
|---|---|---|---|---|
| user | 52 | 0 | 0 | 0 |
| trade | 280 | 0 | 0 | 0 |
| asset | 6 | 0 | 0 | 0 |
| competition | 76 | 0 | 0 | 0 |
| ranking | 3 | 0 | 0 | 0 |
| assistant | 77 | 0 | 0 | 0 |
| notification | 20 | 0 | 0 | 0 |
| **합계** | **514** | **0** | **0** | **0** |

기존 위반은 모두 레이어 의존 방향 규칙에서 나왔다. 주로 컨트롤러 · 응답 DTO 가 domain 모델을 직접 참조하거나,
application 서비스가 presentation DTO 또는 infrastructure 클래스를 직접 쓰는 경우다. 나머지 세 규칙은 위반이 없었다.

### 일부러 위반을 넣었을 때

ranking-service 의 presentation 패키지에 (1) domain repository 를 직접 주입받는 클래스와 (2) 공개 setter 가 있는 `@Entity` 를 넣고 돌렸다.

```
ArchitectureRulesTest > layers FAILED
ArchitectureRulesTest > noEntitySetters FAILED
4 tests completed, 2 failed
```

넣은 두 위반이 각각 해당 규칙에서 잡혔다. 확인 뒤 위반은 지웠고, 다시 돌려 통과를 확인했다.

### 알아 둘 것

- 아키텍처 테스트는 단위 테스트와 다른 소스셋(`src/archTest`)에 있다. trade-service 의 기존 단위 테스트
  (`TradeServiceImplTest`)가 현재 컴파일되지 않아(`requestAccessToken()` 반환 타입 변경 미반영), 같은 소스셋에 두면 구조 규칙도 돌릴 수 없었다.
- 저장소 파일을 새로 만들어야 할 때만 `archunit.properties` 의 `allowStoreCreation` 을 `true` 로 바꿔 한 번 실행한다. 평소에는 `false`.
- 시험한 Windows PC 에서는 `./gradlew archTest` 가 가끔 `java.net.SocketException: Bad address: listen` 으로 실패했다(전체 실행 8회 중 3회 실패, 그중 원인을 직접 확인한 것은 1회).
  Gradle 이 테스트 작업 프로세스와 통신할 소켓을 여는 단계의 오류이고 규칙 위반과는 무관하다. 다시 돌리면 통과한다. CI(Linux) 에서의 동작은 아직 확인하지 않았다.
