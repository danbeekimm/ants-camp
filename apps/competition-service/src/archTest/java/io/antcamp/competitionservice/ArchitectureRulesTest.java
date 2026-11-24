package io.antcamp.competitionservice;

import static com.tngtech.archunit.lang.syntax.ArchRuleDefinition.noClasses;
import static com.tngtech.archunit.lang.syntax.ArchRuleDefinition.noMethods;
import static com.tngtech.archunit.library.Architectures.layeredArchitecture;

import com.tngtech.archunit.core.importer.ImportOption;
import com.tngtech.archunit.junit.AnalyzeClasses;
import com.tngtech.archunit.junit.ArchTag;
import com.tngtech.archunit.junit.ArchTest;
import com.tngtech.archunit.lang.ArchRule;
import com.tngtech.archunit.library.freeze.FreezingArchRule;
import jakarta.persistence.Entity;
import org.springframework.web.bind.annotation.ControllerAdvice;
import org.springframework.web.bind.annotation.RestControllerAdvice;

/**
 * docs/coding-conventions.md 의 규칙 중 코드 구조만 보고 판정할 수 있는 것을 테스트로 옮긴 것.
 *
 * <p>실행: {@code ./gradlew :apps:competition-service:archTest}
 *
 * <p>FreezingArchRule 은 도입 시점의 기존 위반을 {@code archunit_store/} 에 기록해 두고,
 * 그 뒤로는 새로 생긴 위반만 실패시킨다. 기록 파일은 커밋한다.
 */
@ArchTag("arch")
@AnalyzeClasses(packages = "io.antcamp.competitionservice", importOptions = ImportOption.DoNotIncludeTests.class)
class ArchitectureRulesTest {

    // §7 레이어 의존 방향 — 컨트롤러는 application 만 부르고, 바깥 레이어는 안쪽에서 참조되지 않는다.
    @ArchTest
    static final ArchRule layers = FreezingArchRule.freeze(
            layeredArchitecture().consideringOnlyDependenciesInLayers()
                    .withOptionalLayers(true) // infrastructure 가 없는 단순한 서비스도 있다
                    .layer("Presentation").definedBy("..presentation..")
                    .layer("Application").definedBy("..application..")
                    .layer("Domain").definedBy("..domain..")
                    .layer("Infrastructure").definedBy("..infrastructure..")
                    .whereLayer("Presentation").mayNotBeAccessedByAnyLayer()
                    .whereLayer("Application").mayOnlyBeAccessedByLayers("Presentation", "Infrastructure")
                    .whereLayer("Domain").mayOnlyBeAccessedByLayers("Application", "Infrastructure")
                    .whereLayer("Infrastructure").mayNotBeAccessedByAnyLayer());

    // §2 domain 은 바깥 레이어를 모른다.
    @ArchTest
    static final ArchRule domainIsInnermost = FreezingArchRule.freeze(
            noClasses().that().resideInAPackage("..domain..")
                    .should().dependOnClassesThat().resideInAnyPackage("..infrastructure..", "..presentation.."));

    // §1 엔티티에 공개 setter 금지.
    // Lombok 의 @Setter · @Data 는 컴파일 결과에 남지 않으므로, 만들어진 setXxx 메서드를 찾는다.
    @ArchTest
    static final ArchRule noEntitySetters = FreezingArchRule.freeze(
            noMethods().that().areDeclaredInClassesThat().areAnnotatedWith(Entity.class)
                    .and().arePublic()
                    .should().haveNameMatching("set[A-Z].*"));

    // §9 예외 처리기는 common 의 GlobalExceptionHandler 하나만 둔다.
    @ArchTest
    static final ArchRule noServiceLevelExceptionHandler = FreezingArchRule.freeze(
            noClasses().should().beAnnotatedWith(RestControllerAdvice.class)
                    .orShould().beAnnotatedWith(ControllerAdvice.class));
}
