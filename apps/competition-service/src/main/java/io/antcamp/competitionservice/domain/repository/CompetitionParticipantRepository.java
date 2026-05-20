package io.antcamp.competitionservice.domain.repository;

import io.antcamp.competitionservice.domain.model.CompetitionParticipant;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

public interface CompetitionParticipantRepository {

    // Create
    CompetitionParticipant save(CompetitionParticipant participant);

    // Read
    Optional<CompetitionParticipant> findByUserIdAndCompetitionId(UUID userId, UUID competitionId);

    // 소프트 딜리트 포함 조회 (재활성화 용도)
    Optional<CompetitionParticipant> findByUserIdAndCompetitionIdIncludingDeleted(UUID userId, UUID competitionId);

    // 소프트 딜리트 row 재활성화
    CompetitionParticipant reactivate(UUID userId, UUID competitionId);

    // Delete
    void delete(CompetitionParticipant participant, String deletedBy);

    // Search
    List<CompetitionParticipant> findAllByCompetitionId(UUID competitionId);
}
