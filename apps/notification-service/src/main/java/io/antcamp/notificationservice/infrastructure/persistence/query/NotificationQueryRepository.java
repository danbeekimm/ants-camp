package io.antcamp.notificationservice.infrastructure.persistence.query;

import com.querydsl.core.Tuple;
import com.querydsl.core.types.dsl.BooleanExpression;
import com.querydsl.jpa.impl.JPAQueryFactory;
import io.antcamp.notificationservice.domain.model.AlertStatus;
import io.antcamp.notificationservice.domain.repository.NotificationSearchCriteria;
import io.antcamp.notificationservice.infrastructure.entity.NotificationEntity;
import io.antcamp.notificationservice.infrastructure.entity.QNotificationEntity;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.PageImpl;
import org.springframework.data.domain.Pageable;
import org.springframework.stereotype.Repository;

import java.util.EnumMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

@Repository
@RequiredArgsConstructor
public class NotificationQueryRepository {

    private static final QNotificationEntity n = QNotificationEntity.notificationEntity;

    private final JPAQueryFactory queryFactory;

    public Page<NotificationEntity> search(NotificationSearchCriteria criteria, Pageable pageable) {
        BooleanExpression[] conditions = toConditions(criteria);

        List<NotificationEntity> content = queryFactory
                .selectFrom(n)
                .where(conditions)
                .orderBy(n.createdAt.desc())
                .offset(pageable.getOffset())
                .limit(pageable.getPageSize())
                .fetch();

        long total = Optional.ofNullable(
                queryFactory.select(n.count()).from(n).where(conditions).fetchOne()
        ).orElse(0L);

        return new PageImpl<>(content, pageable, total);
    }

    /**
     * 검색 조건(status 제외)으로 필터링한 알림을 상태별로 집계한다.
     * 단일 group by 쿼리로 4개 상태 건수를 한 번에 조회한다.
     */
    public Map<AlertStatus, Long> countByStatus(NotificationSearchCriteria criteria) {
        List<Tuple> rows = queryFactory
                .select(n.status, n.count())
                .from(n)
                .where(toConditions(criteria))
                .groupBy(n.status)
                .fetch();

        Map<AlertStatus, Long> result = new EnumMap<>(AlertStatus.class);
        for (Tuple row : rows) {
            AlertStatus status = row.get(n.status);
            Long count = row.get(n.count());
            if (status != null) {
                result.put(status, count != null ? count : 0L);
            }
        }
        return result;
    }

    private BooleanExpression[] toConditions(NotificationSearchCriteria criteria) {
        return new BooleanExpression[]{
                criteria.status() != null ? n.status.eq(criteria.status()) : null,
                criteria.severity() != null ? n.severity.eq(criteria.severity()) : null,
                criteria.source() != null ? n.source.eq(criteria.source()) : null,
                criteria.job() != null && !criteria.job().isBlank() ? n.job.eq(criteria.job()) : null,
                criteria.from() != null ? n.createdAt.goe(criteria.from()) : null,
                criteria.to() != null ? n.createdAt.loe(criteria.to()) : null,
                criteria.actionUserEmail() != null ? n.actionUserEmail.eq(criteria.actionUserEmail()) : null,
                Boolean.TRUE.equals(criteria.handledOnly()) ? n.resolutionAction.isNotNull() : null
        };
    }
}
