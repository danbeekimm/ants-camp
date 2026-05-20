package io.antcamp.apigateway.filter;

import com.fasterxml.jackson.databind.ObjectMapper;
import io.antcamp.apigateway.dto.User;
import io.antcamp.apigateway.dto.UserResponse;
import lombok.extern.slf4j.Slf4j;
import org.springframework.cloud.gateway.filter.GatewayFilter;
import org.springframework.cloud.gateway.filter.GatewayFilterChain;
import org.springframework.cloud.gateway.filter.factory.AbstractGatewayFilterFactory;
import org.springframework.data.redis.core.ReactiveStringRedisTemplate;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.server.reactive.ServerHttpRequest;
import org.springframework.security.oauth2.jwt.ReactiveJwtDecoder;
import org.springframework.stereotype.Component;
import org.springframework.web.reactive.function.client.WebClient;
import org.springframework.web.server.ServerWebExchange;
import reactor.core.publisher.Mono;

import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.List;
import java.util.UUID;

@Slf4j
@Component
public class CustomAuthFilter extends AbstractGatewayFilterFactory<CustomAuthFilter.Config> {

    // ── 공개 경로 (메서드 무관) ────────────────────────────────────────────────
    private static final List<String> PUBLIC_PREFIXES = List.of(
            "/api/auth/",
            "/api/public/",
            "/api/users/register",
            "/api/notifications/prometheus",
            "/api/notifications/interactions",
            "/api/trades/stock-price-list",
            "/api/trades/realtime/",
            "/api/stocks/realtime/"
    );

    // ── GET 만 공개 허용 ────────────────────────────────────────────────────────
    private static final List<String> PUBLIC_GET_PREFIXES = List.of(
            "/api/competitions",
            "/api/stocks",
            "/api/trades/realtime/status",
            "/api/market/status"
    );

    // ── Redis 캐시 설정 ────────────────────────────────────────────────────────
    private static final String   CACHE_PREFIX = "gateway:user:";
    private static final Duration CACHE_TTL    = Duration.ofMinutes(5);

    private final WebClient                    webClient;
    private final ReactiveJwtDecoder           jwtDecoder;
    private final ReactiveStringRedisTemplate  redisTemplate;
    private final ObjectMapper                 objectMapper;

    public CustomAuthFilter(
            WebClient.Builder webClientBuilder,
            ReactiveJwtDecoder jwtDecoder,
            ReactiveStringRedisTemplate redisTemplate,
            ObjectMapper objectMapper
    ) {
        super(Config.class);
        this.redisTemplate = redisTemplate;
        this.objectMapper  = objectMapper;
        this.jwtDecoder    = jwtDecoder;
        this.webClient     = webClientBuilder.baseUrl("http://user-service").build();
    }

    public static class Config {}

    // ── 필터 실행 ──────────────────────────────────────────────────────────────
    @Override
    public GatewayFilter apply(Config config) {
        return (exchange, chain) -> {
            String path   = exchange.getRequest().getURI().getPath();
            String method = exchange.getRequest().getMethod().name();

            // 1) 메서드 무관 공개 경로
            if (isPublicPath(path)) {
                return chain.filter(exchange);
            }

            // 2) GET 전용 공개 경로 — Authorization 헤더 제거 후 통과
            if ("GET".equals(method) && isPublicGetPath(path)) {
                ServerHttpRequest req = exchange.getRequest().mutate()
                        .headers(h -> h.remove(HttpHeaders.AUTHORIZATION))
                        .build();
                return chain.filter(exchange.mutate().request(req).build());
            }

            // 3) 인증 필요 경로
            ServerHttpRequest secureRequest  = removeSpoofedHeaders(exchange.getRequest());
            ServerWebExchange secureExchange = exchange.mutate().request(secureRequest).build();
            String token = extractBearerToken(secureRequest);

            if (token == null) {
                return unauthorizedResponse(secureExchange, "Authorization header is empty.");
            }

            // ② SecurityContext 재사용 — JWT 이중 검증 제거
            return jwtDecoder.decode(token)
                    .flatMap(jwt -> {
                        String userId = jwt.getSubject();
                        String role   = jwt.getClaimAsString("role");

                        if (userId == null || userId.isBlank()) {
                            return unauthorizedResponse(secureExchange, "JWT subject is empty.");
                        }

                        // ③ role 이 JWT 에 있으면 user-service 호출 없이 즉시 처리
                        if (role != null && !role.isBlank()) {
                            return authenticateFromJwt(secureExchange, chain, userId, role);
                        }

                        // role 이 없으면 user-service / Redis 경유
                        return authenticateUser(secureExchange, chain, userId);
                    })
                    .onErrorResume(e -> {
                        log.warn("[CustomAuthFilter] Invalid JWT: {}", e.getMessage());
                        return unauthorizedResponse(secureExchange, "Invalid token.");
                    });
        };
    }

    // ── ③ JWT claims 에서 직접 인증 (user-service 호출 없음) ─────────────────
    private Mono<Void> authenticateFromJwt(
            ServerWebExchange exchange,
            GatewayFilterChain chain,
            String userId,
            String role
    ) {
        String cacheKey = CACHE_PREFIX + userId;

        // Redis 에서 추가 정보(이름·이메일·전화) 조회 — 실패해도 계속 진행
        return redisTemplate.opsForValue().get(cacheKey)
                // ② Redis 장애 시 user-service 폴백
                .onErrorResume(e -> {
                    log.warn("[CustomAuthFilter] Redis read error, fallback: {}", e.getMessage());
                    return Mono.empty();
                })
                .flatMap(json -> {
                    try {
                        User cached = objectMapper.readValue(json, User.class);
                        ServerHttpRequest req = createAuthenticatedRequest(exchange.getRequest(), cached);
                        return chain.filter(exchange.mutate().request(req).build());
                    } catch (Exception e) {
                        return Mono.empty();
                    }
                })
                .switchIfEmpty(
                        // 캐시 미스 — 최소 헤더만 주입하고 백그라운드에서 user-service 조회·캐시
                        fetchAndCacheUser(userId, role)
                                .flatMap(user -> {
                                    ServerHttpRequest req = createAuthenticatedRequest(exchange.getRequest(), user);
                                    return chain.filter(exchange.mutate().request(req).build());
                                })
                                .onErrorResume(e -> {
                                    // user-service 실패해도 JWT claims 로 최소 헤더 주입
                                    log.warn("[CustomAuthFilter] user-service 조회 실패, JWT 헤더만 주입: {}", e.getMessage());
                                    ServerHttpRequest req = exchange.getRequest().mutate()
                                            .header("X-User-Id", userId)
                                            .header("X-Role",    role)
                                            .headers(h -> h.remove(HttpHeaders.AUTHORIZATION))
                                            .build();
                                    return chain.filter(exchange.mutate().request(req).build());
                                })
                );
    }

    // ── user-service 조회 + Redis 캐시 저장 ───────────────────────────────────
    private Mono<User> fetchAndCacheUser(String userId, String roleHint) {
        String cacheKey = CACHE_PREFIX + userId;
        return webClient.get()
                .uri("/internal/users/{userId}", userId)
                .retrieve()
                .bodyToMono(UserResponse.class)
                .timeout(Duration.ofMillis(3000))
                .flatMap(response -> {
                    if (response == null || !response.success() || response.data() == null) {
                        return Mono.error(new RuntimeException("User not found"));
                    }
                    User user = response.data();
                    // ④ Redis 쓰기 — 에러 로깅
                    try {
                        String json = objectMapper.writeValueAsString(user);
                        redisTemplate.opsForValue().set(cacheKey, json, CACHE_TTL)
                                .subscribe(null,
                                        e -> log.warn("[CustomAuthFilter] Redis write failed: {}", e.getMessage()));
                    } catch (Exception ignored) {}
                    return Mono.just(user);
                });
    }

    // ── 기존 호환 — role 없을 때 (이전 JWT) ───────────────────────────────────
    private Mono<Void> authenticateUser(
            ServerWebExchange exchange,
            GatewayFilterChain chain,
            String userId
    ) {
        String cacheKey = CACHE_PREFIX + userId;
        return redisTemplate.opsForValue().get(cacheKey)
                .onErrorResume(e -> Mono.empty())      // ② Redis 장애 폴백
                .flatMap(json -> {
                    try {
                        User user = objectMapper.readValue(json, User.class);
                        ServerHttpRequest req = createAuthenticatedRequest(exchange.getRequest(), user);
                        return chain.filter(exchange.mutate().request(req).build());
                    } catch (Exception e) {
                        return Mono.empty();
                    }
                })
                .switchIfEmpty(
                        webClient.get()
                                .uri("/internal/users/{userId}", userId)
                                .retrieve()
                                .bodyToMono(UserResponse.class)
                                .timeout(Duration.ofMillis(3000))
                                .flatMap(response -> {
                                    if (response == null || !response.success() || response.data() == null) {
                                        return unauthorizedResponse(exchange, "User authentication failed.");
                                    }
                                    User user = response.data();
                                    if (!"ACTIVE".equals(user.status())) {
                                        return unauthorizedResponse(exchange, "User is not active.");
                                    }
                                    // ④ Redis 쓰기 — 에러 로깅
                                    try {
                                        String json = objectMapper.writeValueAsString(user);
                                        redisTemplate.opsForValue().set(cacheKey, json, CACHE_TTL)
                                                .subscribe(null,
                                                        e -> log.warn("[CustomAuthFilter] Redis write failed: {}", e.getMessage()));
                                    } catch (Exception ignored) {}

                                    log.info("[CustomAuthFilter] Authenticated userId={}, role={}",
                                            user.userId(), user.role());
                                    ServerHttpRequest req = createAuthenticatedRequest(exchange.getRequest(), user);
                                    return chain.filter(exchange.mutate().request(req).build());
                                })
                                .onErrorResume(e -> {
                                    log.error("[CustomAuthFilter] User Server error. userId={}, msg={}",
                                            userId, e.getMessage());
                                    return unauthorizedResponse(exchange, "Authentication server did not respond.");
                                })
                );
    }

    // ── 유틸 ──────────────────────────────────────────────────────────────────
    private String extractBearerToken(ServerHttpRequest request) {
        String auth = request.getHeaders().getFirst(HttpHeaders.AUTHORIZATION);
        if (auth == null || auth.isBlank() || !auth.startsWith("Bearer ")) return null;
        return auth.substring(7);
    }

    private boolean isPublicPath(String path) {
        return PUBLIC_PREFIXES.stream().anyMatch(path::startsWith);
    }

    private boolean isPublicGetPath(String path) {
        return PUBLIC_GET_PREFIXES.stream().anyMatch(path::startsWith);
    }

    private ServerHttpRequest removeSpoofedHeaders(ServerHttpRequest request) {
        return request.mutate()
                .headers(h -> {
                    h.remove("X-User-Id");
                    h.remove("X-Role");
                    h.remove("X-User-Name");
                    h.remove("X-User-Email");
                    h.remove("X-User-Phone");
                }).build();
    }

    private ServerHttpRequest createAuthenticatedRequest(ServerHttpRequest request, User user) {
        String encodedName = URLEncoder.encode(user.name(), StandardCharsets.UTF_8);
        return request.mutate()
                .header("X-User-Id",    user.userId().toString())
                .header("X-Role",       user.role())
                .header("X-User-Name",  encodedName)
                .header("X-User-Email", user.email())
                .header("X-User-Phone", user.phone())
                .headers(h -> h.remove(HttpHeaders.AUTHORIZATION))
                .build();
    }

    private Mono<Void> unauthorizedResponse(ServerWebExchange exchange, String message) {
        log.warn("[CustomAuthFilter] Authentication failed: {}", message);
        exchange.getResponse().setStatusCode(HttpStatus.UNAUTHORIZED);
        return exchange.getResponse().setComplete();
    }
}
