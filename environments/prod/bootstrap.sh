#!/bin/bash
# 최초 설치는 한 번, 앱 복구는 재부팅·MIG 재생성 때마다 실행합니다.
# 이미지·태그·포트는 템플릿 메타데이터, env 값은 Secret Manager에서 읽습니다.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

exec > >(tee -a /var/log/mulo-bootstrap.log) 2>&1
echo "[$(date '+%F %T')] 부팅 스크립트 시작"

retry() {
  local attempts=$1 delay=$2 attempt
  shift 2
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if "$@"; then return 0; fi
    # 명령 인자에 설정값이 들어갈 수 있으므로 명령 이름만 기록합니다.
    echo "재시도 $attempt/$attempts: $1" >&2
    if ((attempt < attempts)); then sleep "$delay"; fi
  done
  return 1
}

md() {
  # 404는 없는 항목, 네트워크·서버 오류는 실패로 구분합니다.
  local path=$1 body code attempt
  body=$(mktemp)
  for ((attempt = 1; attempt <= 5; attempt++)); do
    if code=$(curl -sS --connect-timeout 3 --max-time 10 \
      -H "Metadata-Flavor: Google" -o "$body" -w '%{http_code}' \
      "http://metadata.google.internal/computeMetadata/v1/$path"); then
      case "$code" in
        200) cat "$body"; rm -f "$body"; return 0 ;;
        404) rm -f "$body"; return 4 ;;
      esac
    fi
    if ((attempt < 5)); then sleep 2; fi
  done
  rm -f "$body"
  echo "메타데이터 조회 실패: $path" >&2
  return 1
}

# 설치가 중간에 실패하면 완료 표시를 남기지 않아 다음 부팅에서 다시 설치합니다.
if [ ! -f /var/lib/mulo-setup-done ]; then
  if ! id ubuntu >/dev/null 2>&1; then
    useradd -m -s /bin/bash ubuntu
  fi
  timedatectl set-timezone Asia/Seoul

  if [ ! -f /swapfile ]; then fallocate -l 2G /swapfile; fi
  chmod 600 /swapfile
  if [ "$(blkid -p -s TYPE -o value /swapfile 2>/dev/null || true)" != "swap" ]; then
    mkswap /swapfile
  fi
  if ! swapon --show=NAME --noheadings | grep -Fxq /swapfile; then swapon /swapfile; fi
  if ! grep -Fqx '/swapfile none swap sw 0 0' /etc/fstab; then
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi

  retry 5 10 apt-get update -y
  retry 5 10 apt-get install -y ca-certificates curl gnupg git vim htop net-tools unzip
  if ! command -v docker >/dev/null 2>&1; then
    retry 5 10 curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    retry 5 10 sh /tmp/get-docker.sh
  fi
  retry 5 10 apt-get install -y docker-compose-plugin
  systemctl enable --now docker
  usermod -aG docker ubuntu

  retry 5 10 curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
    -o /tmp/google-cloud-apt-key.gpg
  gpg --batch --yes --dearmor -o /usr/share/keyrings/cloud.google.gpg /tmp/google-cloud-apt-key.gpg
  echo 'deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main' \
    > /etc/apt/sources.list.d/google-cloud-sdk.list
  retry 5 10 apt-get update -y
  retry 5 10 apt-get install -y google-cloud-cli

  retry 5 10 curl -fsSL https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh \
    -o /tmp/add-google-cloud-ops-agent-repo.sh
  retry 5 10 bash /tmp/add-google-cloud-ops-agent-repo.sh --also-install

  touch /var/lib/mulo-setup-done
  echo "초기 셋업 완료"
fi

# chat 이미지를 아직 지정하지 않은 경우에는 기본 설치까지만 수행합니다.
if IMAGE=$(md instance/attributes/app-image); then
  if [ -z "$IMAGE" ]; then
    echo "app-image가 비어 있어 앱 시작을 건너뜁니다."
    exit 0
  fi
else
  md_status=$?
  if [ "$md_status" -eq 4 ]; then
    echo "app-image 메타데이터가 없어 앱 시작을 건너뜁니다."
    exit 0
  fi
  exit "$md_status"
fi

TAG=$(md instance/attributes/app-image-tag)
SECRET=$(md instance/attributes/app-env-secret)
PORT=$(md instance/attributes/app-port)
PROJECT=$(md project/project-id)
if [ -z "$TAG" ] || [ -z "$SECRET" ] || ! [[ "$PORT" =~ ^[0-9]+$ ]] || \
  ((PORT < 1 || PORT > 65535)); then
  echo "앱 태그·시크릿·포트 메타데이터를 확인하세요." >&2
  exit 1
fi
echo "앱 시작: image=$IMAGE:$TAG secret=$SECRET port=$PORT"

# 시작 스크립트는 root로 실행되므로 root의 Docker 인증을 설정합니다.
REGISTRY=${IMAGE%%/*}
retry 5 10 gcloud auth configure-docker "$REGISTRY" --quiet

# 실패한 다운로드로 이전 env를 덮어쓰지 않으며 값은 stdout에 출력하지 않습니다.
umask 077
mkdir -p /opt/app
ENV_TEMP=$(mktemp /opt/app/app.env.XXXXXX)
trap 'rm -f "$ENV_TEMP"' EXIT
retry 6 10 gcloud secrets versions access latest \
  --project="$PROJECT" --secret="$SECRET" --out-file="$ENV_TEMP"
chmod 600 "$ENV_TEMP"
retry 5 15 docker pull "$IMAGE:$TAG"
mv -f "$ENV_TEMP" /opt/app/app.env

# env와 이미지가 준비된 다음 기존 앱을 정상 종료하고 새 앱을 실행합니다.
if docker container inspect app >/dev/null 2>&1; then
  docker stop --time 60 app
  docker rm app
fi
docker run -d --name app --restart unless-stopped \
  --env-file /opt/app/app.env -p "$PORT:$PORT" --stop-timeout 60 "$IMAGE:$TAG"

# Node Exporter는 호스트의 지표를 제공하고 기존 컨테이너는 다시 시작합니다.
if docker container inspect node-exporter >/dev/null 2>&1; then
  docker start node-exporter
else
  retry 5 15 docker pull quay.io/prometheus/node-exporter:latest
  docker run -d --name node-exporter --restart unless-stopped \
    --network host --pid host -v /:/host:ro,rslave \
    quay.io/prometheus/node-exporter:latest --path.rootfs=/host
fi
echo "[$(date '+%F %T')] 앱 시작 완료"
