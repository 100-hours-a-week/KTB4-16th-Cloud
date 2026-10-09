#!/bin/bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

if [ -f /var/lib/mulo-setup-done ]; then
  echo "이미 초기 셋업 완료됨, 건너뜀"
  exit 0
fi

# GCE 시작 스크립트는 로그인 세션 없이 root로 실행되므로 배포 계정을 고정합니다.
if ! id ubuntu >/dev/null 2>&1; then
  useradd -m -s /bin/bash ubuntu
fi

timedatectl set-timezone Asia/Seoul

# e2-small에서 패키지와 컨테이너를 설치하기 전에 스왑을 준비합니다.
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile
fi
chmod 600 /swapfile
if [ "$(blkid -p -s TYPE -o value /swapfile 2>/dev/null || true)" != "swap" ]; then
  mkswap /swapfile
fi
if ! swapon --show=NAME --noheadings | grep -Fxq /swapfile; then
  swapon /swapfile
fi
if ! grep -Fqx '/swapfile none swap sw 0 0' /etc/fstab; then
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

apt-get update -y
apt-get install -y ca-certificates curl gnupg git vim htop net-tools unzip

# Docker Engine과 Compose 플러그인.
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sh /tmp/get-docker.sh
fi
apt-get install -y docker-compose-plugin
systemctl enable --now docker
usermod -aG docker ubuntu

# Google Cloud CLI.
curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
  | gpg --batch --yes --dearmor -o /usr/share/keyrings/cloud.google.gpg
echo 'deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main' \
  > /etc/apt/sources.list.d/google-cloud-sdk.list
apt-get update -y
apt-get install -y google-cloud-cli

# docker 명령을 실행할 ubuntu 계정의 인증 파일을 준비합니다.
runuser -u ubuntu -- env HOME=/home/ubuntu \
  gcloud auth configure-docker asia-northeast3-docker.pkg.dev --quiet

# Cloud Logging·Monitoring Ops Agent.
curl -fsSL https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh \
  -o /tmp/add-google-cloud-ops-agent-repo.sh
bash /tmp/add-google-cloud-ops-agent-repo.sh --also-install

mkdir -p /home/ubuntu/app/data/nginx
mkdir -p /home/ubuntu/app/data/certbot/conf
mkdir -p /home/ubuntu/app/data/certbot/www
chown -R ubuntu:ubuntu /home/ubuntu/app

touch /var/lib/mulo-setup-done
echo "초기 셋업 완료"
