# 배포 가이드 (OCI 단일 인스턴스)

AntCamp는 **OCI Ubuntu(aarch64 / Ampere A1, 4vCPU·24GB) 단일 인스턴스**에서
`docker-compose.lite.yml` 한 파일로 전체 스택(인프라 + 도메인 서비스 8 + 모니터링)을 구동한다.

## 아키텍처 요약

```
GitHub(dev push)
   └─ Actions(cd.yml)
        ├─ detect : 변경 서비스 감지 (common/compose 변경 → 전체)
        ├─ build  : ubuntu-24.04-arm 러너에서 linux/arm64 이미지 빌드 → GHCR push
        └─ deploy : SSH → git 동기화 → docker compose pull + up -d
                         │
                    OCI 인스턴스 (docker-compose.lite.yml)
```

- **빌드는 GitHub ARM 러너**가 담당 → 인스턴스는 `pull`만 (4vCPU 박스에서 빌드 부하 제거)
- 이미지: `ghcr.io/danbeekimm/<service>:latest` (+ `:<commit-sha>`)
- **진입점은 호스트 nginx(80/443)** — TLS 종단 후 내부로 proxy_pass
  - `api.…` → `127.0.0.1:8080`(gateway), `monitoring.…` → `127.0.0.1:3000`(grafana)
  - 모든 컨테이너 포트는 `127.0.0.1` 바인딩(외부 직노출 없음). 기존 정적사이트(80)는 그대로
  - ⚠️ Docker 게시 포트는 호스트 iptables INPUT을 우회하므로, 외부 노출 통제는
    **127.0.0.1 바인딩 + OCI 보안목록(80/443만)**으로 한다

## 메모리 예산 (24GB)

| 서비스 | -Xmx | | 서비스 | -Xmx |
|---|---|---|---|---|
| assistant | 512m | | gateway | 384m |
| trade | 512m | | notification | 384m |
| user/asset/competition/ranking/config/eureka | 256m | | kafka(heap) | 512m |

- 모든 JVM: `-XX:MaxMetaspaceSize=256m -XX:+ExitOnOutOfMemoryError` (각 Dockerfile)
- 추정 총 RSS ≈ 9GB(유휴) / 11~12GB(부하) → **12GB+ 여유**

---

## 1. 인스턴스 최초 셋업 (1회)

```bash
# 인스턴스 SSH 접속 후
git clone https://github.com/danbeekimm/ants-camp.git
cd ants-camp
sudo bash scripts/oci-setup.sh      # docker, swap, 방화벽
# 재로그인 (docker 그룹 적용)

cp .env.example .env && vi .env      # 값 채우기
```

> **⚠️ OCI 포트는 2곳에서 열어야 한다**
> 1. 인스턴스 iptables — `oci-setup.sh`가 처리 (22/80/443)
> 2. **OCI 콘솔 → VCN → 보안 목록/NSG** 에서 80/443 Ingress 허용 (수동)
>
> gateway(8080)/grafana(3000)은 `127.0.0.1` 바인딩이므로 외부에 직접 열지 않는다.

### nginx 리버스 프록시 설정

```bash
sudo cp scripts/nginx/antcamp.conf.example /etc/nginx/sites-available/antcamp.conf
# 도메인/포트 수정 후
sudo ln -s /etc/nginx/sites-available/antcamp.conf /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
sudo certbot --nginx -d api.antcamp.site -d monitoring.antcamp.site   # TLS
```

기존 정적 사이트 server 블록은 건드리지 않는다(별도 server 블록 추가만).

## 2. GitHub Secrets 등록

레포 **Settings → Secrets and variables → Actions** 에 추가:

| Secret | 설명 |
|---|---|
| `OCI_HOST` | 인스턴스 공인 IP / 도메인 |
| `OCI_USER` | SSH 사용자 (예: `ubuntu`) |
| `OCI_SSH_KEY` | SSH 개인키 (PEM 전체) |
| `OCI_APP_DIR` | 레포 경로 (예: `/home/ubuntu/ants-camp`) |
| `OCI_PORT` | (선택) SSH 포트, 기본 22 |

GHCR push/pull 은 워크플로 기본 `GITHUB_TOKEN`으로 처리되므로 별도 토큰 불필요.
(원하면 GHCR 패키지를 public 으로 바꿔 인스턴스 로그인 자체를 생략할 수도 있음)

## 3. 최초 기동

```bash
./deploy.sh deploy     # GHCR 최신 이미지 pull 후 기동
# (이미지가 아직 없으면 폴백) ./deploy.sh build
```

## 4. 평상시 배포

`dev` 브랜치에 push → **자동 배포**. 수동 전체 재배포는
Actions → AntCamp CD → *Run workflow* → `deploy_all = true`.

---

## 운영 명령 (`deploy.sh`)

| 명령 | 동작 |
|---|---|
| `./deploy.sh deploy` | GHCR pull + up (수동 배포) |
| `./deploy.sh build [svc]` | 인스턴스에서 직접 빌드 (폴백) |
| `./deploy.sh logs [svc]` | 로그 follow |
| `./deploy.sh ps` / `down` / `restart [svc]` | 상태 / 중지 / 재시작 |

## 트러블슈팅

- **외부 접속 안 됨** → OCI 보안 목록 Ingress 확인 (iptables만으론 부족)
- **메모리 압박** → `docker stats` 로 확인. 여유가 크니 특정 서비스 힙을 Dockerfile에서 상향 가능
- **GHCR pull 401** → 패키지 권한(레포 연결) 또는 `GITHUB_TOKEN` 권한 확인, 혹은 패키지 public 전환
- **부팅 디스크 부족** → 부트볼륨 100~200GB 확장 권장 (이미지 + postgres/prometheus/loki 데이터)
- **`ubuntu-24.04-arm` 러너 없음** (프라이빗 레포 플랜 제약) → `cd.yml`의 build job을
  `runs-on: ubuntu-latest`로 바꾸고 build 스텝 전에 `docker/setup-qemu-action@v3` 추가
  (QEMU 에뮬레이션 arm64 빌드 — 동작하나 느림). 또는 인스턴스를 self-hosted 러너로 등록.
