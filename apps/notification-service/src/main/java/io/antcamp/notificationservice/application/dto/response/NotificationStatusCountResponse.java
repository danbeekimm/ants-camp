package io.antcamp.notificationservice.application.dto.response;

import io.antcamp.notificationservice.domain.model.AlertStatus;

import java.util.Map;

/**
 * 알림 상태별 건수 응답. 필터(심각도·소스) 적용 후 전체 및 4개 상태별 카운트를 담는다.
 */
public record NotificationStatusCountResponse(
        long total,
        long pending,
        long sent,
        long failed,
        long actionFailed
) {
    public static NotificationStatusCountResponse of(Map<AlertStatus, Long> counts) {
        long pending = counts.getOrDefault(AlertStatus.PENDING, 0L);
        long sent = counts.getOrDefault(AlertStatus.SENT, 0L);
        long failed = counts.getOrDefault(AlertStatus.FAILED, 0L);
        long actionFailed = counts.getOrDefault(AlertStatus.ACTION_FAILED, 0L);
        return new NotificationStatusCountResponse(
                pending + sent + failed + actionFailed,
                pending, sent, failed, actionFailed
        );
    }
}
