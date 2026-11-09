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

configure_alloy() {
  # 기존 VM의 최초 설치 표시와 무관하게 Alloy를 설치·설정합니다.
  # frontend에는 alloy-service 메타데이터가 없으므로 설치하지 않습니다.
  if ALLOY_SERVICE=$(md instance/attributes/alloy-service); then
    ALLOY_ENVIRONMENT=$(md instance/attributes/alloy-environment)
    ALLOY_LOKI_URL=$(md instance/attributes/alloy-loki-url)

    if ! command -v alloy >/dev/null 2>&1; then
      mkdir -p /etc/apt/keyrings
      retry 5 10 curl -fsSL https://apt.grafana.com/gpg-full.key \
        -o /etc/apt/keyrings/grafana.asc
      chmod 644 /etc/apt/keyrings/grafana.asc
      echo 'deb [signed-by=/etc/apt/keyrings/grafana.asc] https://apt.grafana.com stable main' \
        > /etc/apt/sources.list.d/grafana.list
      retry 5 10 apt-get update -y
      retry 5 10 apt-get install -y alloy
    fi

    usermod -aG docker alloy
    install -d -m 0750 -o root -g alloy /etc/alloy
    ALLOY_CONFIG=$(mktemp /etc/alloy/config.alloy.XXXXXX)
    cat > "$ALLOY_CONFIG" <<EOF
discovery.docker "containers" {
  host             = "unix:///var/run/docker.sock"
  refresh_interval = "5s"
}

discovery.relabel "docker_logs" {
  targets = []

  rule {
    source_labels = ["__meta_docker_container_name"]
    regex         = "/(.*)"
    target_label  = "container"
  }
}

loki.source.docker "containers" {
  host          = "unix:///var/run/docker.sock"
  targets       = discovery.docker.containers.targets
  relabel_rules = discovery.relabel.docker_logs.rules

  labels = {
    job         = "docker-logs",
    environment = "$ALLOY_ENVIRONMENT",
    service     = "$ALLOY_SERVICE",
    instance    = constants.hostname,
  }

  forward_to = [loki.write.monitoring.receiver]
}

loki.write "monitoring" {
  endpoint {
    url = "$ALLOY_LOKI_URL"
  }
}
EOF
    if ! alloy validate "$ALLOY_CONFIG"; then
      rm -f "$ALLOY_CONFIG"
      echo "Alloy 설정 검증 실패" >&2
      exit 1
    fi
    chown root:alloy "$ALLOY_CONFIG"
    chmod 640 "$ALLOY_CONFIG"
    mv -f "$ALLOY_CONFIG" /etc/alloy/config.alloy

    # Docker 소켓이 준비된 뒤 시작하고 docker 그룹 권한을 새 프로세스에 반영합니다.
    mkdir -p /etc/systemd/system/alloy.service.d
    cat > /etc/systemd/system/alloy.service.d/docker.conf <<'EOF'
[Unit]
Requires=docker.service
After=docker.service
EOF
    systemctl daemon-reload
    systemctl enable alloy
    retry 3 5 systemctl restart alloy
    systemctl is-active --quiet alloy

    # Loki가 아직 준비되지 않아도 앱 부팅은 계속하고 Alloy가 전송을 재시도합니다.
    if ! curl -fsS --connect-timeout 3 --max-time 5 \
      "${ALLOY_LOKI_URL%/loki/api/v1/push}/ready"; then
      echo "Loki가 아직 준비되지 않았습니다. Alloy 로그와 모니터링 VM을 확인하세요." >&2
    fi
    echo "Alloy 설정 완료: environment=$ALLOY_ENVIRONMENT service=$ALLOY_SERVICE"
  else
    md_status=$?
    if [ "$md_status" -ne 4 ]; then exit "$md_status"; fi
  fi
}

# 별도 Bash의 엄격 모드로 실패를 감지하되, Alloy 오류가 앱 시작을 중단하지 않게 합니다.
# if 안에서 함수를 직접 호출하면 Bash의 set -e가 함수 내부에서도 무시될 수 있습니다.
if ! (
  export -f retry md configure_alloy
  exec /bin/bash -c 'set -euo pipefail; configure_alloy'
); then
  echo "Alloy 설정에 실패했습니다. 앱 시작은 계속합니다. /var/log/mulo-bootstrap.log를 확인하세요." >&2
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
