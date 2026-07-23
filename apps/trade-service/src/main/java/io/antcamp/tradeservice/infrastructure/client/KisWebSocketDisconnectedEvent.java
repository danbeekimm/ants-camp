package io.antcamp.tradeservice.infrastructure.client;

/**
 * KIS WebSocket 연결 종료 이벤트
 *
 * KisWebSocketHandler(afterConnectionClosed)가 발행하고
 * KisWebSocketClient가 수신해 백오프 재연결을 수행한다.
 * (핸들러 → 클라이언트 직접 참조 시 순환 의존이 생기므로 이벤트로 분리)
 */
public record KisWebSocketDisconnectedEvent(String reason) {}
