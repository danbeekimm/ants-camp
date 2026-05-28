package io.antcamp.assistantservice.infrastructure.scheduler;

import io.antcamp.assistantservice.application.service.RagApplicationService;
import io.antcamp.assistantservice.domain.repository.ChatSessionRepository;
import io.antcamp.assistantservice.domain.model.ChatMessage;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import java.time.LocalDateTime;
import java.util.List;

@Slf4j
@Component
@RequiredArgsConstructor
public class ChatReconciler {

    private static final int PENDING_TIMEOUT_MINUTES = 5;
    private static final int MAX_RETRY = 3;

    private final ChatSessionRepository chatSessionRepository;
    private final RagApplicationService ragApplicationService;

    // 봇 응답 없이 PENDING 상태로 남은 유저 메시지 재처리 (MAX_RETRY 도달 시 FAILED 전이로 무한 재시도 차단)
    @Scheduled(fixedDelay = 60_000)
    public void reconcile() {
        LocalDateTime threshold = LocalDateTime.now().minusMinutes(PENDING_TIMEOUT_MINUTES);
        List<ChatMessage> targets = chatSessionRepository.findReconcileTargets(threshold, MAX_RETRY);
        if (targets.isEmpty()) return;

        log.warn("미응답 메시지 재처리 시작: {}건", targets.size());
        for (ChatMessage message : targets) {
            try {
                ragApplicationService.retryPendingMessage(message);
                log.info("미응답 메시지 재처리 완료: chatMessageId={}", message.getChatMessageId());
            } catch (Exception e) {
                message.incrementRetry();
                if (message.getRetryCount() >= MAX_RETRY) {
                    message.markFailed(e.getMessage());
                    log.error("재처리 {}회 초과 — FAILED 전이: chatMessageId={}",
                            MAX_RETRY, message.getChatMessageId(), e);
                } else {
                    log.warn("재처리 실패({}/{}): chatMessageId={}",
                            message.getRetryCount(), MAX_RETRY, message.getChatMessageId(), e);
                }
                chatSessionRepository.save(message);
            }
        }
    }
}
