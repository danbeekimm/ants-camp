package io.antcamp.assistantservice.application.service;

import io.antcamp.assistantservice.application.dto.command.RunPairwiseCommand;
import io.antcamp.assistantservice.application.port.JudgeLlmPort;
import io.antcamp.assistantservice.domain.model.PairwiseResult;
import io.antcamp.assistantservice.domain.model.RagQuerySnapshot;
import io.antcamp.assistantservice.domain.model.Verdict;
import io.antcamp.assistantservice.domain.repository.PairwiseRepository;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.scheduling.annotation.Async;
import org.springframework.stereotype.Component;

import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.stream.Collectors;

@Slf4j
@Component
@RequiredArgsConstructor
public class PairwiseProcessor {

    private final JudgeLlmPort judgeLlmPort;
    private final PairwiseRepository pairwiseRepository;

    @Async("evalExecutor")
    public void comparePairwise(UUID pairwiseRunId, RunPairwiseCommand command) {
        try {
            Map<String, String> responsesA = loadResponses(command.evalRunIdA());
            Map<String, String> responsesB = loadResponses(command.evalRunIdB());

            Set<String> sharedQuestions = responsesA.keySet().stream()
                    .filter(responsesB::containsKey)
                    .collect(Collectors.toSet());

            log.info("Pairwise 비교 시작: runA={}, runB={}, 공통 질문 수={}",
                    command.evalRunIdA(), command.evalRunIdB(), sharedQuestions.size());

            if (sharedQuestions.isEmpty()) {
                log.warn("Pairwise 공통 질문 없음: runA={}, runB={}", command.evalRunIdA(), command.evalRunIdB());
                pairwiseRepository.markFailed(pairwiseRunId);
                return;
            }

            int total = sharedQuestions.size() * command.judgeModels().size();
            pairwiseRepository.markRunning(pairwiseRunId, total);

            for (String question : sharedQuestions) {
                for (String judgeModel : command.judgeModels()) {
                    compareAndSave(command, question,
                            responsesA.get(question), responsesB.get(question), judgeModel);
                    pairwiseRepository.incrementDone(pairwiseRunId);
                }
            }

            pairwiseRepository.markCompleted(pairwiseRunId);
        } catch (Exception e) {
            log.error("Pairwise 처리 중 예외 발생: runA={}, runB={}",
                    command.evalRunIdA(), command.evalRunIdB(), e);
            pairwiseRepository.markFailed(pairwiseRunId);
        }
    }

    private Map<String, String> loadResponses(UUID evalRunId) {
        return pairwiseRepository
                .findRagSnapshotsByRunId(evalRunId)
                .stream()
                .collect(Collectors.toMap(RagQuerySnapshot::userQuery, RagQuerySnapshot::llmResponse));
    }

    // 양방향 평가로 위치 편향(앞쪽 유리) 차단:
    //   forward  : (A, B) → judge가 [응답 A]=responseA, [응답 B]=responseB 로 인식
    //   reverse  : (B, A) → judge가 [응답 A]=responseB, [응답 B]=responseA 로 인식
    //   reverse 결과를 원래 A/B 관점으로 swap 후 두 방향 일치하면 그 결과, 불일치 시 TIE
    private void compareAndSave(RunPairwiseCommand command, String question,
                                  String responseA, String responseB, String judgeModel) {
        try {
            Verdict forwardVerdict = judgeLlmPort.compare(judgeModel, question, responseA, responseB);
            Verdict reverseVerdict = judgeLlmPort.compare(judgeModel, question, responseB, responseA);

            PairwiseResult result = PairwiseResult.createCounterbalanced(
                    command.evalRunIdA(), command.evalRunIdB(), question, judgeModel,
                    forwardVerdict, reverseVerdict);
            pairwiseRepository.save(result);

            if (result.exposedPositionBias()) {
                log.warn("Pairwise 위치 편향 노출 → TIE 처리: judgeModel={}, question={}, fwd={}, rev={}",
                        judgeModel, question, forwardVerdict, reverseVerdict);
            } else {
                log.info("Pairwise 판정 완료: judgeModel={}, question={}, fwd={}, rev={}, verdict={}",
                        judgeModel, question, forwardVerdict, reverseVerdict, result.getVerdict());
            }
        } catch (Exception e) {
            log.error("Pairwise 판정 실패, 해당 조합 건너뜀: judgeModel={}, question={}", judgeModel, question, e);
        }
    }
}
