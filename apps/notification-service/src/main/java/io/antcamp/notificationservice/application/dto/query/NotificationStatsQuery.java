package io.antcamp.notificationservice.application.dto.query;

import io.antcamp.notificationservice.domain.model.AlertSeverity;
import io.antcamp.notificationservice.domain.model.AlertSource;
import io.antcamp.notificationservice.domain.repository.NotificationSearchCriteria;

public record NotificationStatsQuery(
        AlertSeverity severity,
        AlertSource source
) {
    /**
     * 상태별 집계용 검색 조건. status 는 group by 기준이므로 null 로 둔다.
     */
    public NotificationSearchCriteria toCriteria() {
        return new NotificationSearchCriteria(
                null, severity, source, null, null, null, null, null
        );
    }
}
