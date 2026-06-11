#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────
# OCI 단일 인스턴스(Ubuntu aarch64) 운영 헬퍼
#   - 평상시 배포는 GitHub Actions(cd.yml)가 GHCR 이미지를 pull 한다.
#   - 이 스크립트는 인스턴스에서 수동 운영/디버깅/폴백 빌드용이다.
#
# 사용법:
#   ./deploy.sh deploy        # GHCR 최신 이미지 pull 후 기동 (수동 배포)
#   ./deploy.sh up            # 로컬에 있는 이미지로 기동 (pull 없이)
#   ./deploy.sh build [svc]   # 인스턴스에서 직접 빌드 (레지스트리 없이 폴백)
#   ./deploy.sh pull          # 이미지만 pull
#   ./deploy.sh down          # 전체 중지
#   ./deploy.sh restart [svc] # 재시작
#   ./deploy.sh logs [svc]    # 로그 follow
#   ./deploy.sh ps            # 상태
# ──────────────────────────────────────────────────────────────────────────

COMPOSE_FILE="docker-compose.lite.yml"
DC=(docker compose -f "$COMPOSE_FILE")

cd "$(dirname "$0")"

[ -f .env ] || { echo "❌ .env 가 없습니다. .env.example 를 복사해 채우세요."; exit 1; }

cmd="${1:-deploy}"
shift || true

case "$cmd" in
  deploy)
    echo "▶ GHCR 이미지 pull"
    "${DC[@]}" pull
    echo "▶ 컨테이너 기동/갱신"
    "${DC[@]}" up -d --remove-orphans
    docker image prune -f
    "${DC[@]}" ps
    ;;
  up)
    "${DC[@]}" up -d --remove-orphans "$@"
    ;;
  pull)
    "${DC[@]}" pull "$@"
    ;;
  build)
    echo "▶ 인스턴스에서 직접 빌드 (느림 — 폴백용)"
    "${DC[@]}" build "$@"
    "${DC[@]}" up -d --remove-orphans "$@"
    ;;
  restart)
    "${DC[@]}" restart "$@"
    ;;
  down)
    "${DC[@]}" down
    ;;
  logs)
    "${DC[@]}" logs -f --tail=200 "$@"
    ;;
  ps)
    "${DC[@]}" ps
    ;;
  *)
    echo "Usage: $0 {deploy|up|pull|build|restart|down|logs|ps} [service...]"
    exit 1
    ;;
esac
