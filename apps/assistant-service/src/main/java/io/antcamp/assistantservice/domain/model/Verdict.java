package io.antcamp.assistantservice.domain.model;

// Pairwise 비교 판정 결과
public enum Verdict {
    A_WINS,         // Run A의 응답이 더 좋음
    B_WINS,         // Run B의 응답이 더 좋음
    TIE;            // 비슷한 수준

    // 위치 교차 평가(A/B 자리 바꿈) 결과를 원래 A/B 관점으로 정규화
    public Verdict swap() {
        return switch (this) {
            case A_WINS -> B_WINS;
            case B_WINS -> A_WINS;
            case TIE    -> TIE;
        };
    }
}
