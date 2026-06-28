# tests/ — API 실행 테스트 산출물

`/apitest` skill(`docs/automation-workflow.md` B)이 빌드·단위 테스트 후 API 시나리오를 실행하고 결과를 이 디렉토리에 저장한다.

## 레이아웃

```
tests/
├── README.md                       # (이 파일) 레이아웃 설명 — 버전관리 대상
├── cases/                          # (선택) 재사용 테스트 케이스 정의 — 버전관리 대상
└── results/                        # 실행 결과 — .gitignore 처리(커밋 안 함)
    └── <YYYYMMDD_HHMMSS>/
        ├── summary.md              # 환경 + 빌드/단위테스트 + 시나리오 케이스별 통과/실패 표
        ├── 01_<name>.req.http      # 케이스별 요청 (토큰/시크릿 마스킹)
        ├── 01_<name>.res.json      # 케이스별 응답 (상태코드 포함)
        ├── 02_<name>.req.http
        └── 02_<name>.res.json
```

## 규칙

- 호출 기준은 **게이트웨이** `http://localhost:8080`. 자격증명·변수는 루트 `http-client.env.json`(`local` 환경)을 따른다.
- 시나리오 원본은 루트 `scenario.http` / `scenario_all.http` / `scenario_trading.http`.
- `results/`는 매 실행마다 타임스탬프 디렉토리로 쌓인다 — **커밋하지 않는다**(`tests/.gitignore`).
- 저장물에 JWT/토큰/`KIS_*`/`*_API_KEY`/비밀번호가 평문으로 남지 않도록 **마스킹**한다.

## summary.md 형식

```
# apitest — <대상 서비스/시나리오>  (<timestamp>)

## 환경
- gateway: http://localhost:8080  (health: UP)
- infra: docker compose up (postgres/redis/kafka/config/eureka)

## 빌드 & 단위 테스트
- build: ✅  | unit test: ✅ (N passed)

## API 시나리오
| # | 케이스 | 메서드 | 엔드포인트 | 기대 | 실제 | 결과 |
|---|--------|--------|-----------|------|------|------|
| 01 | 대회 생성 | POST | /api/competitions | 201 | 201 | ✅ |

## 합계
- 12 / 12 통과
```
