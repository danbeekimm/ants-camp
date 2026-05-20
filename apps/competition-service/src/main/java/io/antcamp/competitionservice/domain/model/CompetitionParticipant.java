package io.antcamp.competitionservice.domain.model;

import java.util.UUID;
import lombok.AccessLevel;
import lombok.Builder;
import lombok.Getter;

@Getter
public class CompetitionParticipant {

    private final UUID participantId;
    private final UUID userId;
    private final String username;
    private final UUID competitionId;
    private final boolean deleted; // 소프트 딜리트 여부

    @Builder(access = AccessLevel.PRIVATE)
    private CompetitionParticipant(
            UUID participantId,
            UUID userId,
            String username,
            UUID competitionId,
            boolean deleted
    ) {
        this.participantId = participantId;
        this.userId = userId;
        this.username = username;
        this.competitionId = competitionId;
        this.deleted = deleted;
    }

    // ─── 정적 팩토리 메서드 ───────────────────────────────────────────────

    public static CompetitionParticipant create(UUID userId, String username, UUID competitionId) {
        return CompetitionParticipant.builder()
                .participantId(UUID.randomUUID())
                .userId(userId)
                .username(username)
                .competitionId(competitionId)
                .deleted(false)
                .build();
    }

    public static CompetitionParticipant reconstitute(
            UUID participantId,
            UUID userId,
            String username,
            UUID competitionId,
            boolean deleted
    ) {
        return CompetitionParticipant.builder()
                .participantId(participantId)
                .userId(userId)
                .username(username)
                .competitionId(competitionId)
                .deleted(deleted)
                .build();
    }

    // ─── 도메인 행위 ─────────────────────────────────────────────────────

    public boolean isSameCompetition(UUID competitionId) {
        return this.competitionId.equals(competitionId);
    }
}
