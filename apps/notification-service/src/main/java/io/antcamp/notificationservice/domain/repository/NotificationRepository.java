package io.antcamp.notificationservice.domain.repository;

import io.antcamp.notificationservice.domain.model.AlertStatus;
import io.antcamp.notificationservice.domain.model.Notification;

import java.util.Map;
import java.util.Optional;
import java.util.UUID;

public interface NotificationRepository {

    Notification save(Notification notification);

    Optional<Notification> findById(UUID notificationId);

    Optional<Notification> findByIdForUpdate(UUID notificationId);

    PageResult<Notification> search(NotificationSearchCriteria criteria, PagingRequest pagingRequest);

    /**
     * 검색 조건(status 제외)에 해당하는 알림을 상태별로 집계한다.
     * 건수가 0인 상태는 결과 맵에 포함되지 않을 수 있다.
     */
    Map<AlertStatus, Long> countByStatus(NotificationSearchCriteria criteria);
}
