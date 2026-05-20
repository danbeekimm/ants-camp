package io.antcamp.competitionservice.application;

import common.exception.BusinessException;
import common.exception.ErrorCode;
import io.antcamp.competitionservice.application.dto.CancelCompetitionCommand;
import io.antcamp.competitionservice.application.dto.JoinCompetitionCommand;
import io.antcamp.competitionservice.domain.event.CompetitionCancelledEvent;
import io.antcamp.competitionservice.domain.event.CompetitionRegisteredEvent;
import io.antcamp.competitionservice.domain.model.Competition;
import io.antcamp.competitionservice.domain.model.CompetitionParticipant;
import io.antcamp.competitionservice.domain.repository.CompetitionParticipantRepository;
import io.antcamp.competitionservice.domain.repository.CompetitionRepository;
import java.time.LocalDateTime;
import java.util.List;
import java.util.UUID;
import lombok.RequiredArgsConstructor;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

@Service
@RequiredArgsConstructor
public class CompetitionParticipantServiceImpl implements CompetitionParticipantService {

    private final CompetitionRepository competitionRepository;
    private final CompetitionParticipantRepository competitionParticipantRepository;
    private final ApplicationEventPublisher applicationEventPublisher;

    @Transactional
    public CompetitionParticipant registerCompetition(JoinCompetitionCommand command) {
        // 1. 대회 조회 (Competition 비관적 락 먼저 획득 - 같은 대회 신청 요청을 직렬화)
        Competition competition = competitionRepository.findByIdWithLock(command.competitionId())
                .orElseThrow(() -> new BusinessException(ErrorCode.COMPETITION_NOT_FOUND));

        if (competition.getRegisterPeriod().getEndAt().isBefore(LocalDateTime.now())) {
            // 대회 신청기간이 지나서 신청할 수 없습니다 예외 반환
            throw new BusinessException(ErrorCode.COMPETITION_CANNOT_REGISTER);
        }

        // 2. 중복 신청 체크 — 소프트 딜리트 포함 전체 row 조회
        //    활성 row: 이미 신청 → COMPETITION_ALREADY_REGISTERED
        //    소프트 딜리트 row: 이전에 취소했다가 재신청 → 재활성화
        //    없음: 신규 삽입
        var existingOpt = competitionParticipantRepository
                .findByUserIdAndCompetitionIdIncludingDeleted(command.userId(), command.competitionId());

        competition.register();
        competitionRepository.save(competition);

        // 3. 참여자 저장 (신규 or 재활성화)
        CompetitionParticipant saved;
        if (existingOpt.isPresent()) {
            // 활성 row → 중복
            if (!existingOpt.get().isDeleted()) {
                throw new BusinessException(ErrorCode.COMPETITION_ALREADY_REGISTERED);
            }
            // 소프트 딜리트 row → 재활성화
            saved = competitionParticipantRepository.reactivate(command.userId(), command.competitionId());
        } else {
            CompetitionParticipant participant = CompetitionParticipant.create(
                    command.userId(),
                    command.username(),
                    command.competitionId()
            );
            saved = competitionParticipantRepository.save(participant);
        }

        // 4. Spring 내부 이벤트 발행 → DB 커밋 완료 후 리스너가 Kafka로 전달
        applicationEventPublisher.publishEvent(new CompetitionRegisteredEvent(
                competition.getCompetitionId(),
                competition.getName(),
                competition.getType().name(),
                competition.getFirstSeed(),
                command.userId()
        ));

        return saved;
    }

    @Transactional
    public CompetitionParticipant cancelRegistration(CancelCompetitionCommand command) {
        // 1. 대회 조회 (Competition 비관적 락 - 참가자 수 동시성 제어)
        Competition competition = competitionRepository.findByIdWithLock(command.competitionId())
                .orElseThrow(() -> new BusinessException(ErrorCode.COMPETITION_NOT_FOUND));
        competition.cancelRegister();
        competitionRepository.save(competition);

        // 2. 참여자 조회 (비관적 락)
        CompetitionParticipant participant = competitionParticipantRepository
                .findByUserIdAndCompetitionId(command.userId(), command.competitionId())
                .orElseThrow(() -> new BusinessException(ErrorCode.COMPETITION_PARTICIPANT_NOT_FOUND));

        // 3. 참여자 삭제
        competitionParticipantRepository.delete(participant, command.userId().toString());

        // 4. Spring 내부 이벤트 발행 → DB 커밋 완료 후 리스너가 Kafka로 전달
        applicationEventPublisher.publishEvent(new CompetitionCancelledEvent(
                command.competitionId(),
                command.userId()
        ));

        return participant;
    }

    // 대회 참가자 목록 조회
    @Transactional(readOnly = true)
    public List<CompetitionParticipant> findAllByCompetitionId(UUID competitionId) {
        return competitionParticipantRepository.findAllByCompetitionId(competitionId);
    }
}
