#!/bin/bash
# Redis VM의 컨테이너 실행 기반만 준비합니다. Redis의 이미지·설정·데이터는 직접 관리합니다.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=l

if [ "$(id -u)" -ne 0 ]; then
  echo "root 권한으로 실행하세요: sudo bash redis-bootstrap.sh" >&2
  exit 1
fi

. /etc/os-release
if [ "$ID" != "ubuntu" ]; then
  echo "이 스크립트는 Ubuntu Redis VM 전용입니다." >&2
  exit 1
fi

# 완료 마커 대신 실제 설치 상태를 검사해 누락된 구성만 설치합니다.
packages=()
if ! command -v docker >/dev/null 2>&1; then
  packages+=(docker-ce docker-ce-cli containerd.io)
fi
if ! docker compose version >/dev/null 2>&1; then
  packages+=(docker-compose-plugin)
fi

if [ "${#packages[@]}" -gt 0 ]; then
  apt-get -o DPkg::Lock::Timeout=120 -o Acquire::Retries=3 update
  apt-get -o DPkg::Lock::Timeout=120 install -y --no-install-recommends ca-certificates curl

  # 기존 Docker 저장소가 있으면 재사용해 중복 Signed-By 설정을 피합니다.
  if ! grep -RqsE '^(deb .*https://download.docker.com/linux/ubuntu|URIs: *https://download.docker.com/linux/ubuntu)' \
    /etc/apt/sources.list /etc/apt/sources.list.d; then
    install -m 0755 -d /etc/apt/keyrings
    curl --retry 3 -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  fi

  apt-get -o DPkg::Lock::Timeout=120 -o Acquire::Retries=3 update
  apt-get -o DPkg::Lock::Timeout=120 install -y --no-install-recommends "${packages[@]}"
fi

# 이미 실행 중인 Docker를 재시작하지 않고 부팅 시 자동 시작을 보장합니다.
systemctl enable --now docker
docker version --format 'Docker Engine {{.Server.Version}}'
docker compose version
echo "Redis VM의 Docker 준비 완료"
