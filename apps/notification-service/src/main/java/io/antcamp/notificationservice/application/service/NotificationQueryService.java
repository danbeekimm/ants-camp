package io.antcamp.notificationservice.application.service;

import io.antcamp.notificationservice.application.dto.query.NotificationSearchQuery;
import io.antcamp.notificationservice.application.dto.query.NotificationStatsQuery;
import io.antcamp.notificationservice.application.dto.response.NotificationDetailResponse;
import io.antcamp.notificationservice.application.dto.response.NotificationStatusCountResponse;
import io.antcamp.notificationservice.application.dto.response.NotificationSummaryResponse;
import io.antcamp.notificationservice.domain.exception.NotificationException;
import io.antcamp.notificationservice.domain.model.AlertStatus;
import io.antcamp.notificationservice.domain.model.Notification;
import io.antcamp.notificationservice.domain.repository.NotificationRepository;
import io.antcamp.notificationservice.domain.repository.PageResult;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.List;
import java.util.Map;
import java.util.UUID;

@Service
@RequiredArgsConstructor
@Transactional(readOnly = true)
public class NotificationQueryService {

    private static final int PAGE_SIZE = 30;

    private final NotificationRepository notificationRepository;

    public PageResult<NotificationSummaryResponse> search(NotificationSearchQuery query) {
        PageResult<Notification> result = notificationRepository.search(
                query.toCriteria(), query.toPagingRequest(PAGE_SIZE));
        List<NotificationSummaryResponse> content = result.content().stream()
                .map(NotificationSummaryResponse::of)
                .toList();
        return new PageResult<>(content, result.totalElements(), result.totalPages(), result.currentPage());
    }

    public NotificationStatusCountResponse countByStatus(NotificationStatsQuery query) {
        Map<AlertStatus, Long> counts = notificationRepository.countByStatus(query.toCriteria());
        return NotificationStatusCountResponse.of(counts);
    }

    public NotificationDetailResponse findById(UUID notificationId) {
        return notificationRepository.findById(notificationId)
                .map(NotificationDetailResponse::of)
                .orElseThrow(NotificationException::notFound);
    }
}