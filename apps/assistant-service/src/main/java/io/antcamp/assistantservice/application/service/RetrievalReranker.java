package io.antcamp.assistantservice.application.service;

import io.antcamp.assistantservice.application.config.RetrievalProperties;
import io.antcamp.assistantservice.application.port.VectorStorePort.SearchedChunk;
import io.antcamp.assistantservice.domain.model.DocType;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Component;

import java.util.Comparator;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * 벡터 검색 후보를 질문 의도에 맞게 리랭킹하고, 관련성이 약한 청크를 컷오프한다.
 *
 * <p>유사도 하한(similarityThreshold)만으로는 부족하다. 질문에 따라 1위 점수 자체가 크게 다르고,
 * 짧은 질문은 전반적으로 점수가 낮게 나오기 때문이다. 그래서 절대 하한은 벡터 검색 단계에 맡기고,
 * 여기서는 (1) 질문 의도와 맞는 문서 타입에 가산점을 주고 (2) 1위 점수 대비 상대 비율로 컷오프한다.</p>
 */
@Slf4j
@Component
@RequiredArgsConstructor
public class RetrievalReranker {

    private final RetrievalProperties properties;

    // 의도 키워드 → 우대할 문서 타입. 사용법/정의 질문은 GUIDE·FAQ를, 권한/규정 질문은 POLICY·TERMS를 우대한다.
    private static final List<String> HOW_TO_KEYWORDS =
            List.of("어떻게", "방법", "하려면", "하는 법", "하나요", "신청", "설정", "사용");
    private static final List<String> DEFINITION_KEYWORDS =
            List.of("차이", "뭐예요", "뭔가요", "무엇", "뭐야", "의미", "란", "이란");
    private static final List<String> POLICY_KEYWORDS =
            List.of("규정", "약관", "정책", "권한", "할 수 있나요", "되나요", "가능한가요", "가능한가", "제한");

    /**
     * @param query      사용자 질문
     * @param candidates 벡터 검색이 유사도 내림차순으로 반환한 후보들
     * @return 의도 가중치 반영·컷오프 후 최종 topK 청크(유사도 점수는 원본 유지)
     */
    public List<SearchedChunk> rerank(String query, List<SearchedChunk> candidates) {
        if (candidates.isEmpty()) {
            return candidates;
        }

        Set<String> preferredTypes = preferredDocTypes(query);

        List<Scored> scored = candidates.stream()
                .map(c -> new Scored(c, effectiveScore(c, preferredTypes)))
                .sorted(Comparator.comparingDouble(Scored::score).reversed())
                .toList();

        // score gap 컷오프: 1위(=가장 관련 높은) 점수의 일정 비율 미만이면 노이즈로 보고 제외
        double cutoff = scored.get(0).score() * properties.scoreGapRatio();

        List<SearchedChunk> result = scored.stream()
                .filter(s -> s.score() >= cutoff)
                .limit(properties.topK())
                .map(Scored::chunk)
                .toList();

        log.debug("리랭킹: 후보={}, 선정={}, 컷오프={}, 우대타입={}",
                candidates.size(), result.size(), String.format("%.3f", cutoff), preferredTypes);
        return result;
    }

    private double effectiveScore(SearchedChunk chunk, Set<String> preferredTypes) {
        double base = chunk.score() != null ? chunk.score() : 0.0;
        return preferredTypes.contains(chunk.docType()) ? base + properties.intentBoost() : base;
    }

    private Set<String> preferredDocTypes(String query) {
        Set<String> types = new HashSet<>();
        if (containsAny(query, HOW_TO_KEYWORDS) || containsAny(query, DEFINITION_KEYWORDS)) {
            types.add(DocType.GUIDE.name());
            types.add(DocType.FAQ.name());
        }
        if (containsAny(query, POLICY_KEYWORDS)) {
            types.add(DocType.POLICY.name());
            types.add(DocType.TERMS.name());
        }
        return types;
    }

    private boolean containsAny(String query, List<String> keywords) {
        return keywords.stream().anyMatch(query::contains);
    }

    private record Scored(SearchedChunk chunk, double score) {}
}