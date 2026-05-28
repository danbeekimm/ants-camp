package io.antcamp.assistantservice.domain.model;

import lombok.AccessLevel;
import lombok.Builder;
import lombok.Getter;

import java.util.UUID;

@Getter
@Builder(access = AccessLevel.PRIVATE)
public class PairwiseResult {

    private UUID pairwiseResultId;
    private UUID evalRunIdA;
    private UUID evalRunIdB;
    private String question;
    private String judgeModel;
    private Verdict verdict;            // 양방향 합산 결과 — 집계용
    private Verdict forwardVerdict;     // (A,B) 정방향 판정
    private Verdict reverseVerdict;     // (B,A) 역방향 판정 (원래 A/B 관점으로 정규화 전 원본)

    // 양방향 평가 결과 합산: 두 방향 일치 시 그 결과, 불일치 시 TIE (위치 편향 노출 차단)
    public static PairwiseResult createCounterbalanced(UUID evalRunIdA, UUID evalRunIdB,
                                                       String question, String judgeModel,
                                                       Verdict forwardVerdict, Verdict reverseVerdict) {
        Verdict reverseNormalized = reverseVerdict.swap();
        Verdict aggregated = (forwardVerdict == reverseNormalized) ? forwardVerdict : Verdict.TIE;
        return PairwiseResult.builder()
                .pairwiseResultId(UUID.randomUUID())
                .evalRunIdA(evalRunIdA)
                .evalRunIdB(evalRunIdB)
                .question(question)
                .judgeModel(judgeModel)
                .verdict(aggregated)
                .forwardVerdict(forwardVerdict)
                .reverseVerdict(reverseVerdict)
                .build();
    }

    public boolean exposedPositionBias() {
        return forwardVerdict != null
                && reverseVerdict != null
                && forwardVerdict != reverseVerdict.swap();
    }

    public static PairwiseResult restore(UUID pairwiseResultId, UUID evalRunIdA, UUID evalRunIdB,
                                          String question, String judgeModel, Verdict verdict,
                                          Verdict forwardVerdict, Verdict reverseVerdict) {
        return PairwiseResult.builder()
                .pairwiseResultId(pairwiseResultId)
                .evalRunIdA(evalRunIdA)
                .evalRunIdB(evalRunIdB)
                .question(question)
                .judgeModel(judgeModel)
                .verdict(verdict)
                .forwardVerdict(forwardVerdict)
                .reverseVerdict(reverseVerdict)
                .build();
    }
}
