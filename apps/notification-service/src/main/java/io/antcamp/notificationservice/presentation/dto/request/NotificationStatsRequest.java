package io.antcamp.notificationservice.presentation.dto.request;

import io.antcamp.notificationservice.application.dto.query.NotificationStatsQuery;
import io.antcamp.notificationservice.domain.model.AlertSeverity;
import io.antcamp.notificationservice.domain.model.AlertSource;

/**
 * 알림 상태별 카운트 조회 요청.
 * 알림 관리 페이지의 2개 필터(심각도·소스)에 따라 전체/상태별 건수를 한 번에 집계한다.
 * 상태(status)는 집계 기준(group by)이므로 필터로 받지 않는다.
 */
public record NotificationStatsRequest(
        AlertSeverity severity,
        AlertSource source
) {
    public NotificationStatsQuery toQuery() {
        return new NotificationStatsQuery(severity, source);
    }
}
