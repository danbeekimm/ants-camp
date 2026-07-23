package io.antcamp.tradeservice.infrastructure.client;

import com.fasterxml.jackson.databind.ObjectMapper;
import io.antcamp.tradeservice.application.service.TradeService;
import io.antcamp.tradeservice.infrastructure.config.handler.KisWebSocketHandler;
import jakarta.annotation.PostConstruct;
import jakarta.annotation.PreDestroy;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.event.EventListener;
import org.springframework.stereotype.Component;
import org.springframework.web.socket.TextMessage;
import org.springframework.web.socket.WebSocketSession;
import org.springframework.web.socket.client.standard.StandardWebSocketClient;

import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * KIS WebSocket 연결 관리 클라이언트
 *
 * 책임:
 *  1. 애플리케이션 시작 시 WS 연결 (@PostConstruct)
 *  2. 종목 구독/해제 메시지 전송 (구독 종목은 재연결 대비 자체 보관)
 *  3. 연결 종료(KisWebSocketDisconnectedEvent) 시 백오프 재연결 + 기존 구독 복구
 *  4. 애플리케이션 종료 시 WS 연결 해제 (@PreDestroy)
 *
 * 실시간 데이터 수신·파싱·브로드캐스트는 KisWebSocketHandler 가 담당.
 */
@Slf4j
@Component
@RequiredArgsConstructor
public class KisWebSocketClient {

    /** 재연결 백오프 상한 (초) */
    private static final long MAX_RECONNECT_DELAY_SEC = 60;

    @Value("${kis.ws.url}")
    private String wsUrl;

    private final TradeService tradeService;
    private final KisWebSocketHandler kisWebSocketHandler;
    private final ObjectMapper objectMapper;

    private volatile WebSocketSession session;

    /** 재연결 시 복구할 구독 종목 (체결가 / 호가 별도 관리) */
    private final Set<String> priceSubs     = ConcurrentHashMap.newKeySet();
    private final Set<String> orderBookSubs = ConcurrentHashMap.newKeySet();

    private final ScheduledExecutorService reconnectExecutor =
            Executors.newSingleThreadScheduledExecutor(r -> {
                Thread t = new Thread(r, "kis-ws-reconnect");
                t.setDaemon(true);
                return t;
            });
    private final AtomicBoolean reconnectScheduled = new AtomicBoolean(false);
    private final AtomicInteger reconnectAttempts  = new AtomicInteger(0);
    private volatile boolean shuttingDown = false;

    // ─────────────────────────────────────────────────────────────────────

    /**
     * 1단계: REST API 로 WebSocket 접속키(approval_key) 발급
     * 2단계: WebSocket 연결
     *
     * @PostConstruct — Spring 컨텍스트 초기화 완료 후 자동 실행
     */
    @PostConstruct
    public void connect() {
        doConnect();
    }

    /** KIS 측 연결 종료 감지 → 백오프 재연결 */
    @EventListener
    public void onDisconnected(KisWebSocketDisconnectedEvent event) {
        if (shuttingDown) return;
        this.session = null;
        scheduleReconnect();
    }

    private void doConnect() {
        if (shuttingDown || isConnected()) return;
        try {
            // KIS: POST /oauth2/Approval → approval_key (REST access_token 과 별개)
            String approvalKey = tradeService.requestApprovalKey();
            log.info("KIS 접속키 발급 완료");

            StandardWebSocketClient client = new StandardWebSocketClient();
            client.execute(kisWebSocketHandler, wsUrl)
                    .whenComplete((wsSession, ex) -> {
                        if (ex != null) {
                            log.error("KIS WebSocket 연결 실패: {}", ex.getMessage(), ex);
                            scheduleReconnect();
                            return;
                        }
                        this.session = wsSession;
                        reconnectAttempts.set(0);
                        log.info("KIS WebSocket 연결 성공: {}", wsUrl);
                        resubscribeAll();
                    });

        } catch (Exception e) {
            log.error("KIS WebSocket 초기화 실패: {}", e.getMessage(), e);
            scheduleReconnect();
        }
    }

    private void scheduleReconnect() {
        if (shuttingDown) return;
        if (!reconnectScheduled.compareAndSet(false, true)) return; // 이미 예약됨

        int attempt = reconnectAttempts.incrementAndGet();
        long delaySec = Math.min(MAX_RECONNECT_DELAY_SEC, 1L << Math.min(attempt, 6)); // 2,4,8,...60
        log.warn("KIS WebSocket {}초 후 재연결 시도 (attempt={})", delaySec, attempt);

        reconnectExecutor.schedule(() -> {
            reconnectScheduled.set(false);
            doConnect();
        }, delaySec, TimeUnit.SECONDS);
    }

    /** 재연결 직후 기존 구독 종목 복구 */
    private void resubscribeAll() {
        if (priceSubs.isEmpty() && orderBookSubs.isEmpty()) return;
        priceSubs.forEach(code -> sendSubscribeMessage(code, "H0STCNT0", "1"));
        orderBookSubs.forEach(code -> sendSubscribeMessage(code, "H0STASP0", "1"));
        log.info("KIS 재구독 복구: 체결 {}종목, 호가 {}종목", priceSubs.size(), orderBookSubs.size());
    }

    // ─── 구독 / 해제 ─────────────────────────────────────────────────────

    /** 국내주식 실시간 체결가 구독 (H0STCNT0) */
    public void subscribe(String stockCode) {
        priceSubs.add(stockCode);
        sendSubscribeMessage(stockCode, "H0STCNT0", "1");
    }

    /** 체결가 구독 해제 */
    public void unsubscribe(String stockCode) {
        priceSubs.remove(stockCode);
        sendSubscribeMessage(stockCode, "H0STCNT0", "2");
    }

    /** 국내주식 실시간 호가 구독 (H0STASP0) */
    public void subscribeOrderBook(String stockCode) {
        orderBookSubs.add(stockCode);
        sendSubscribeMessage(stockCode, "H0STASP0", "1");
    }

    /** 호가 구독 해제 */
    public void unsubscribeOrderBook(String stockCode) {
        orderBookSubs.remove(stockCode);
        sendSubscribeMessage(stockCode, "H0STASP0", "2");
    }

    /**
     * KIS WebSocket 구독 메시지 전송
     *
     * @param stockCode 종목코드
     * @param trId      TR 코드 (H0STCNT0: 체결, H0STASP0: 호가)
     * @param trType    "1": 등록, "2": 해제
     */
    private void sendSubscribeMessage(String stockCode, String trId, String trType) {
        if (!isConnected()) {
            // 등록 요청은 priceSubs/orderBookSubs 에 남아 있어 재연결 시 자동 복구된다
            log.warn("WebSocket 미연결 — stockCode={}, trId={}", stockCode, trId);
            return;
        }
        try {
            String approvalKey = tradeService.requestApprovalKey();

            Map<String, Object> request = Map.of(
                    "header", Map.of(
                            "approval_key", approvalKey,
                            "custtype",     "P",
                            "tr_type",      trType,
                            "content-type", "utf-8"
                    ),
                    "body", Map.of(
                            "input", Map.of(
                                    "tr_id",  trId,
                                    "tr_key", stockCode
                            )
                    )
            );

            session.sendMessage(new TextMessage(objectMapper.writeValueAsString(request)));
            log.info("구독 {} 완료: {} ({})", "1".equals(trType) ? "등록" : "해제", stockCode, trId);

        } catch (Exception e) {
            log.error("구독 메시지 전송 실패 [stockCode={}, trId={}]: {}", stockCode, trId, e.getMessage(), e);
        }
    }

    // ─────────────────────────────────────────────────────────────────────

    public boolean isConnected() {
        WebSocketSession s = session;
        return s != null && s.isOpen();
    }

    @PreDestroy
    public void disconnect() {
        shuttingDown = true;
        reconnectExecutor.shutdownNow();
        if (isConnected()) {
            try {
                session.close();
                log.info("KIS WebSocket 정상 종료");
            } catch (Exception e) {
                log.error("WebSocket 종료 실패: {}", e.getMessage());
            }
        }
    }
}
