# Antcamp 개발 개념 정리

> 프로젝트를 진행하면서 마주친 핵심 개념들을 백엔드 / 프론트엔드 / 인프라로 구분하여 정리한 문서입니다.

---

## 1. 백엔드

### Spring Cloud Gateway & Filter 체인

Spring Cloud Gateway는 모든 요청이 통과하는 진입점이다. 필터는 두 종류가 있다.

- **GlobalFilter**: 모든 라우트에 적용. Spring Security도 GlobalFilter로 동작한다.
- **GatewayFilter**: 특정 라우트에만 적용. `AbstractGatewayFilterFactory`를 상속해서 구현한다.

**핵심 주의사항**: Spring Security의 `SecurityWebFilterChain`은 GatewayFilter보다 먼저 실행된다. 따라서 커스텀 인증 필터에서 공개 경로로 지정한 경로도 `SecurityWebFilterChain`의 `permitAll()`에 동일하게 등록해야 한다. 한쪽만 설정하면 여전히 401이 반환된다.

```java
// SecurityConfig와 CustomAuthFilter 양쪽에 모두 등록해야 함
private static final List<String> PUBLIC_PREFIXES = List.of(
    "/api/auth/",
    "/api/users/register",
    "/api/trades/stock-price-list"
    // ...
);
```

---

### JWT + Redis 사용자 캐싱 패턴

매 요청마다 user-service를 호출하면 레이턴시가 누적된다. Gateway에서 JWT 클레임을 직접 파싱하고, 사용자 정보를 Redis에 5분간 캐싱하면 user-service 호출을 대부분 생략할 수 있다.

```
요청 수신
  → JWT 파싱 (userId, role 추출)
  → Redis 조회 (gateway:user:{userId})
      ├─ 캐시 HIT  → 헤더에 userId/role 주입 후 다음 서비스로 전달
      └─ 캐시 MISS → user-service 호출 → Redis 저장 (TTL 5분) → 전달
```

Redis 쓰기는 **fire-and-forget**으로 처리하되, 반드시 에러 콜백을 달아야 한다. `.subscribe()`만 호출하면 실패해도 조용히 넘어가서 디버깅이 어렵다.

```java
redisTemplate.opsForValue()
    .set(key, json, CACHE_TTL)
    .subscribe(
        result -> log.debug("Redis 캐시 저장 성공: {}", key),
        err    -> log.warn("Redis 캐시 저장 실패 (무시): {}", err.getMessage())
    );
```

---

### Eureka 서비스 디스커버리

Feign Client의 `name` 속성은 Eureka에 등록된 서비스 이름과 **정확히 일치**해야 한다. 대소문자는 무관하지만 kebab-case/camelCase 혼용은 장애 원인이 된다.

```java
// ❌ Eureka에 'asset-service'로 등록됐는데
@FeignClient(name = "assetClient")

// ✅ 반드시 일치시켜야 함
@FeignClient(name = "asset-service")
```

컨테이너 재시작 시 Eureka에 중복 인스턴스가 등록되는 문제가 있다. 컨테이너 ID가 매번 바뀌기 때문이다. 환경변수로 고정 instance-id를 설정하면 해결된다.

```yaml
EUREKA_INSTANCE_INSTANCE_ID: asset-service:8086
EUREKA_INSTANCE_STATUS_PAGE_URL: http://${HOST_IP}:8086/actuator/info
EUREKA_INSTANCE_HEALTH_CHECK_URL: http://${HOST_IP}:8086/actuator/health
```

---

### WebSocket 자동 재연결

KIS(한국투자증권) WebSocket은 서버가 30초마다 `PINGPONG` 메시지를 보낸다. `"PONG"` 으로 응답하지 않으면 연결이 끊긴다. 또한 네트워크 불안정이나 서버 재시작으로 연결이 끊길 수 있어서 자동 재연결 로직이 필수다.

```java
@Override
public void afterConnectionClosed(WebSocketSession session, CloseStatus status) {
    log.warn("KIS WebSocket 연결 종료: status={}", status);
    reconnectAsync(); // @Async + 30초 딜레이 후 재연결
}
```

`@Async`를 사용하려면 `@SpringBootApplication` 클래스에 `@EnableAsync`를 반드시 추가해야 한다.

---

### KIS REST API 레이트 리밋

KIS API는 초당 호출 제한이 있다. 여러 종목 가격을 연속으로 조회하면 429 또는 500 에러가 발생한다. 호출 간에 딜레이를 추가하고, `RetryableException`은 전파하지 않고 기본값("0")을 반환하는 방어 코드가 필요하다.

```java
for (String code : stockCodes) {
    Thread.sleep(100); // 호출 간 100ms 딜레이
    try {
        // KIS API 호출
    } catch (RetryableException e) {
        priceMap.put(code, "0"); // 실패 시 0으로 폴백
    }
}
```

---

### Reactive vs Blocking

Spring WebFlux 기반의 Gateway에서는 블로킹 코드를 절대 직접 호출하면 안 된다. `WebClient`(논블로킹)를 사용하고, `Mono`/`Flux` 체인으로 처리해야 한다. 반면 일반 Spring MVC 서비스(trade-service 등)에서는 `RestTemplate` 또는 `FeignClient`를 사용한다.

---

## 2. 프론트엔드

### fetchWithAuth — JWT 자동 갱신 패턴

`fetch`를 직접 쓰면 accessToken 만료 시 401을 그냥 받아버린다. `fetchWithAuth` 래퍼를 만들어 401 응답 시 refreshToken으로 토큰을 재발급하고 원래 요청을 재시도하는 패턴을 쓴다.

```ts
async function fetchWithAuth(url, options) {
  let res = await fetch(url, withToken(options))
  if (res.status === 401) {
    const newToken = await refreshAccessToken() // refresh 요청
    if (newToken) {
      res = await fetch(url, withToken(options, newToken)) // 재시도
    } else {
      redirectToLogin()
    }
  }
  return res
}
```

공개 엔드포인트(대회 목록 조회 등)는 `fetchWithAuth` 대신 plain `fetch`를 써야 한다. 토큰이 없는 비로그인 사용자도 접근해야 하기 때문이다.

---

### STOMP WebSocket + 폴백 패턴

실시간 주가 데이터는 STOMP over WebSocket으로 수신한다. 그러나 장 마감이나 연결 지연 등으로 STOMP 데이터가 없을 수 있다. 이 경우 REST API로 현재가를 폴백으로 보여주는 패턴이 필요하다.

```ts
// STOMP 가격 없을 때만 REST 조회
useEffect(() => {
  const stompPrice = stocks[selectedCode]?.price?.currentPrice
  if (stompPrice) return // STOMP 데이터 있으면 스킵
  fetchStockPriceList([selectedCode])
    .then((map) => setRestPrice(map[selectedCode] ?? null))
}, [selectedCode, stocks])

// 렌더링 시 우선순위: STOMP > REST > null
const currentPrice = price?.currentPrice ?? restPrice
```

---

### Vite 경로 별칭 (Path Alias)

`tsconfig.json`의 `paths` 설정은 TypeScript 컴파일러(IDE 자동완성)용이고, Vite 번들러는 별도로 `vite.config.ts`에 `resolve.alias`를 설정해야 한다. 둘 다 설정해야 빌드도 되고 IDE 빨간 줄도 사라진다.

```ts
// vite.config.ts
resolve: {
  alias: { '@': fileURLToPath(new URL('./src', import.meta.url)) }
}
```

```json
// tsconfig.json
"paths": { "@/*": ["./src/*"] }  // 반드시 /* 와일드카드 포함
```

`"@/*": ["./src"]`처럼 `/*`를 빼면 IDE에서 경로를 못 찾는다.

---

### Zustand 상태 관리

전역 상태는 Zustand로 관리한다. `localStorage`와 연동할 때는 `persist` 미들웨어를 사용한다. 토큰처럼 민감한 정보는 store를 통해서만 접근하는 게 이상적이지만, 일부 서비스 함수에서 `localStorage.getItem('accessToken')`을 직접 읽는 패턴도 흔하게 사용된다.

---

### Vercel 배포 방식 비교

| 방식 | PR merge 기록 | Preview 배포 | 설정 복잡도 |
|------|-------------|-------------|-----------|
| Git Integration | ✅ 자동 기록 | ✅ PR마다 자동 | 낮음 (대시보드에서 레포 연결만) |
| GitHub Actions CLI | ❌ push 이벤트만 | ❌ 직접 구현 필요 | 높음 (Secrets 3개 필요) |

Git Integration 방식이 더 간단하고 Vercel의 기능(PR Preview, 롤백, 배포 기록)을 풍부하게 쓸 수 있다.

---

### TypeScript 엄격 모드 주의사항

`tsconfig.json`에 `"noUnusedLocals": true`, `"noUnusedParameters": true`가 설정되어 있으면 사용하지 않는 import/변수가 있을 때 빌드가 실패한다. 개발 중에는 IDE 경고로만 보이다가 `npm run build` 시 에러로 터지는 경우가 많다.

```ts
// ❌ 빌드 실패
import type { Competition } from '@/types/auth' // Competition을 쓰지 않으면 에러

// ✅ 쓰는 것만 import
import type { MyRankingHistory } from '@/types/auth'
```

---

## 3. 인프라

### Docker 멀티 플랫폼 빌드

M1/M2 Mac(ARM64)에서 빌드한 이미지를 GCP/AWS의 x86(amd64) VM에서 실행하면 플랫폼 불일치로 컨테이너가 시작되지 않거나 성능이 크게 저하된다. 빌드 시 반드시 타겟 플랫폼을 명시해야 한다.

```bash
docker build --platform linux/amd64 -t my-service:latest .
```

---

### GCP 핵심 서비스 구성

| 서비스 | 역할 | AWS 대응 |
|--------|------|---------|
| Artifact Registry | 컨테이너 이미지 저장소 | ECR |
| Compute Engine | 가상 머신 | EC2 |
| Cloud Memorystore | 관리형 Redis | ElastiCache |
| Cloud SQL | 관리형 PostgreSQL | RDS |
| Cloud NAT | Private VM의 외부 인터넷 아웃바운드 | NAT Gateway |
| IAP (Identity-Aware Proxy) | VPN 없이 내부 VM SSH 접근 | SSM Session Manager |

GCP VM에서 Artifact Registry 이미지를 pull 하려면 먼저 인증 설정이 필요하다.

```bash
gcloud auth configure-docker asia-northeast3-docker.pkg.dev
```

---

### Prometheus 스크래핑 구조

Prometheus는 각 서비스의 `/actuator/prometheus` 엔드포인트를 주기적으로 pull 방식으로 수집한다. 모니터링 VM이 앱 VM의 내부 IP로 직접 접근할 수 있어야 한다. 앱 VM과 모니터링 VM이 같은 VPC 내에 있으면 내부 IP(10.x.x.x)로 통신 가능하다.

```yaml
# prometheus.yaml
scrape_configs:
  - job_name: 'trade-service'
    static_configs:
      - targets: ['10.178.0.2:8084']
    metrics_path: '/actuator/prometheus'
```

Spring Boot 서비스에서 Prometheus 엔드포인트를 노출하려면 의존성과 설정이 필요하다.

```yaml
# application.yaml
management:
  endpoints:
    web:
      exposure:
        include: health,info,prometheus
  metrics:
    export:
      prometheus:
        enabled: true
```

---

### Loki + Promtail 로그 수집 구조

```
각 서비스 컨테이너 로그
  → Promtail (앱 VM에서 Docker 로그 수집)
  → Loki (모니터링 VM에서 저장)
  → Grafana (쿼리 및 시각화)
```

Promtail은 Docker 컨테이너의 로그를 읽기 위해 `/var/lib/docker/containers` 를 마운트해야 한다. Grafana에서 Loki 데이터소스를 추가할 때 URL은 내부 IP로 설정한다.

---

### Alertmanager 알림 흐름

```
Prometheus (규칙 평가)
  → Alertmanager (알림 집계·라우팅)
  → notification-service webhook (POST /api/notifications/prometheus)
  → 슬랙 / 이메일 등
```

`alertmanager.yaml`을 외부 볼륨 마운트로 주입하면 Docker가 파일 대신 디렉토리를 생성해버리는 문제가 있다. 이미지 빌드 시 파일을 직접 복사(bake-in)하는 방식이 더 안정적이다.

```dockerfile
COPY --chown=nobody:nobody alertmanager.yaml /etc/alertmanager/alertmanager.yaml
```

Prometheus도 동일하게 `nobody` 유저로 실행되므로 `--chown=nobody:nobody`가 필요하다. Grafana는 UID 472로 실행된다.

---

### Nginx 리버스 프록시

외부에서 단일 도메인(api.antcamp.site)으로 들어오는 요청을 내부 서비스로 라우팅한다. Spring Cloud Gateway가 내부 라우팅을 담당하더라도, 앞단에 Nginx를 두면 SSL 종료, 로드밸런싱, 정적 파일 서빙 등을 분리할 수 있다.

```nginx
server {
    listen 80;
    server_name api.antcamp.site;

    location / {
        proxy_pass http://localhost:8080;  # Spring Cloud Gateway
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }

    # WebSocket 업그레이드
    location /ws-stomp {
        proxy_pass http://localhost:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

---

### GitHub Actions CI/CD vs Vercel Git Integration

GitHub Actions로 `vercel deploy` CLI를 직접 호출하는 방식은 Vercel이 Git 이벤트(PR merge, push)를 인식하지 못한다. Vercel 대시보드에서 GitHub 레포를 직접 연결하는 Git Integration 방식을 쓰면 push/PR merge 시 자동 배포되고, PR마다 Preview URL이 생성된다.

---

### 환경변수 관리 전략

| 방법 | 장점 | 단점 |
|------|------|------|
| `.env` 파일 직접 관리 | 간단 | 실수로 커밋될 위험, 서버마다 수동 관리 |
| AWS SSM Parameter Store | 중앙 관리, IAM 권한 제어 | AWS 종속 |
| GCP Secret Manager | 중앙 관리, IAM 권한 제어 | GCP 종속 |
| Docker Compose `env_file` | 컨테이너별 분리 | 파일 서버에 존재 |

프로덕션에서는 SSM 또는 Secret Manager로 중앙 관리하고, 배포 스크립트에서 값을 가져와 컨테이너 환경변수로 주입하는 패턴이 권장된다.

---

### Config Server 브랜치 / 경로 설정

Spring Cloud Config Server는 Git 레포에서 설정 파일을 읽어온다. 브랜치와 `search-paths`가 실제 파일 위치와 일치해야 각 서비스가 설정을 올바르게 받아온다.

```yaml
spring:
  cloud:
    config:
      server:
        git:
          default-label: dev          # 브랜치명
          search-paths: configs/{application}  # 서비스별 디렉토리
```

`{application}`은 각 서비스의 `spring.application.name` 값으로 치환된다.
