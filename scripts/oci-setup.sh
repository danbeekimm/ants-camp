#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────
# OCI Ubuntu (aarch64 / Ampere A1) 단일 인스턴스 1회성 부트스트랩
#
# 수행 작업
#   1) Docker Engine + compose plugin 설치 (ARM)
#   2) 현재 사용자 docker 그룹 추가
#   3) swap 4GB 생성 (빌드/피크 대비)
#   4) 인스턴스 방화벽(iptables) 개방: 22(SSH), 80, 443 — nginx가 진입점
#      ※ gateway(8080)/grafana(3000)은 127.0.0.1 바인딩이라 호스트 개방 불필요
#      ※ OCI는 "보안 목록(Security List/NSG)"도 별도로 80/443 을 열어야 외부 접속됨!
#
# 실행:  sudo bash scripts/oci-setup.sh
# ──────────────────────────────────────────────────────────────────────────

if [ "$(id -u)" -ne 0 ]; then echo "sudo 로 실행하세요: sudo bash $0"; exit 1; fi

TARGET_USER="${SUDO_USER:-ubuntu}"
OPEN_PORTS=(22 80 443)   # nginx가 80/443에서 gateway/grafana로 프록시

echo "════════ 1. Docker 설치 ════════"
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com | sh
else
  echo "docker 이미 설치됨: $(docker --version)"
fi
systemctl enable --now docker

echo "════════ 2. ${TARGET_USER} 를 docker 그룹에 추가 ════════"
usermod -aG docker "$TARGET_USER" || true
echo "  (적용하려면 ${TARGET_USER} 재로그인 필요)"

echo "════════ 3. swap 4GB ════════"
if ! swapon --show | grep -q '/swapfile'; then
  fallocate -l 4G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=4096
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo "  swap 생성 완료"
else
  echo "  swap 이미 존재"
fi

echo "════════ 4. 방화벽(iptables) 개방 ════════"
# OCI Ubuntu 이미지는 INPUT 체인에 REJECT 규칙이 기본 존재한다.
# 각 포트 ACCEPT 규칙을 REJECT 앞(상단)에 삽입한다.
for p in "${OPEN_PORTS[@]}"; do
  if ! iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null; then
    iptables -I INPUT 6 -p tcp --dport "$p" -j ACCEPT
    echo "  +tcp/$p ACCEPT"
  else
    echo "  tcp/$p 이미 허용"
  fi
done
# 영구 저장
if ! command -v netfilter-persistent >/dev/null 2>&1; then
  DEBIAN_FRONTEND=noninteractive apt-get update -y && apt-get install -y iptables-persistent
fi
netfilter-persistent save

cat <<'EOF'

════════ 완료 ════════
다음 단계:
  1) (중요) OCI 콘솔 → VCN → 보안 목록/NSG 에서 80,443(,22) Ingress 허용
  2) 재로그인 후 docker 그룹 적용 확인:  docker ps
  3) 레포 클론:  git clone https://github.com/danbeekimm/ants-camp.git
  4) .env 작성:  cp .env.example .env  (값 채우기)
  5) 최초 기동:  ./deploy.sh deploy   (또는 폴백: ./deploy.sh build)
  6) nginx 프록시:  scripts/nginx/antcamp.conf.example 참고해 site 추가 후 reload
     (gateway/grafana는 127.0.0.1 이므로 nginx가 443→프록시. 기존 정적사이트는 그대로 둠)
EOF
