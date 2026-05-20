package io.antcamp.assistantservice.application.config;

import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.boot.context.properties.bind.DefaultValue;

/**
 * RAG 검색 튜닝 설정.
 *
 * <p>topK 고정 검색은 질문과 무관한 문서까지 항상 컨텍스트에 채워 넣는 문제가 있어,
 * 유사도 하한(similarityThreshold) + score gap 컷오프 + 문서 타입 가중치로 노이즈를 걷어낸다.
 * 적정값은 데이터셋마다 다르므로(특히 한국어 임베딩) 코드 상수가 아닌 설정으로 빼서 실측 튜닝한다.</p>
 */
@ConfigurationProperties(prefix = "assistant.retrieval")
public record RetrievalProperties(
        // 최종적으로 컨텍스트에 포함할 문서(청크) 수
        @DefaultValue("5") int topK,
        // 후보 풀 배수 — 리랭킹/컷오프 여지를 주기 위해 topK * 배수 만큼 먼저 검색한다
        @DefaultValue("3") int candidateMultiplier,
        // 코사인 유사도 하한(0.0~1.0). 이 값 미만 청크는 벡터 검색 단계에서 제외해 명백한 노이즈를 컷한다.
        // Spring AI 기본은 0.0(=컷 없음). 한국어 임베딩 기준 0.5~0.75 사이가 출발점이며 실측 후 조정.
        @DefaultValue("0.5") double similarityThreshold,
        // 1위 점수 대비 비율 컷오프. 1위의 (scoreGapRatio)배 미만인 청크는 제외한다. 1.0이면 비활성.
        @DefaultValue("0.8") double scoreGapRatio,
        // 질문 의도와 일치하는 문서 타입에 부여하는 가산점(코사인 점수에 직접 더함)
        @DefaultValue("0.05") double intentBoost
) {
    /** 리랭킹 전 1차로 검색할 후보 수 */
    public int candidateTopK() {
        return topK * Math.max(1, candidateMultiplier);
    }
}