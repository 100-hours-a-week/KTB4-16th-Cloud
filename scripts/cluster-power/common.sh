#!/bin/bash
# cluster-stop.sh / cluster-start.sh가 함께 쓰는 함수 모음입니다. 직접 실행하지 않습니다.
# macOS 기본 bash(3.2)에서도 돌도록 연관 배열·mapfile을 쓰지 않습니다.

set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-mulo-prod}"
export AWS_REGION="${AWS_REGION:-ap-northeast-2}"
export AWS_PAGER=""
NAME_PREFIX="${NAME_PREFIX:-mulo-v3-prod}"
EXPECTED_CP=3

# 워커를 끄는 동안 ASG가 인스턴스를 고장으로 보고 지우거나 새로 띄우지 않게 멈출 프로세스입니다.
# AddToLoadBalancer는 그대로 둡니다(대상 그룹 등록은 인스턴스를 켜면 그대로 유지됩니다).
ASG_PROCESSES="Launch Terminate HealthCheck ReplaceUnhealthy AZRebalance InstanceRefresh ScheduledActions"

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '\033[1;33m[%s] 주의:\033[0m %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
die()  { printf '\033[1;31m[%s] 중단:\033[0m %s\n' "$(date '+%H:%M:%S')" "$*" >&2; exit 1; }

confirm() {
  [[ "${ASSUME_YES:-0}" == 1 ]] && return 0
  local answer
  read -r -p "$1 계속하려면 yes 입력: " answer
  [[ "$answer" == yes ]] || die "사용자가 취소했습니다."
}

check_tools() {
  local t
  for t in aws jq base64; do command -v "$t" >/dev/null || die "$t 명령이 필요합니다."; done
  aws sts get-caller-identity --query Account --output text >/dev/null 2>&1 \
    || die "AWS 자격 증명을 읽지 못했습니다(AWS_PROFILE=$AWS_PROFILE)."
}

# CP 인스턴스 ID(종료되지 않은 것). 공백으로 구분해 출력합니다.
cp_ids() {
  aws ec2 describe-instances \
    --filters "Name=tag:Role,Values=control-plane" "Name=tag:Name,Values=${NAME_PREFIX}-cp-*" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text
}

asg_names() {
  aws autoscaling describe-auto-scaling-groups \
    --query "AutoScalingGroups[?starts_with(AutoScalingGroupName, '${NAME_PREFIX}-')].AutoScalingGroupName" \
    --output text
}

# 워커 ASG에 속한 인스턴스 ID. ASG 프로세스를 멈춘 상태면 중지된 인스턴스도 그대로 속해 있습니다.
worker_ids() {
  local asgs
  asgs="$(asg_names)"
  [[ -z "$asgs" ]] && return 0
  # shellcheck disable=SC2086
  aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $asgs \
    --query 'AutoScalingGroups[].Instances[].InstanceId' --output text
}

desired_total() {
  aws autoscaling describe-auto-scaling-groups \
    --query "sum(AutoScalingGroups[?starts_with(AutoScalingGroupName, '${NAME_PREFIX}-')].DesiredCapacity)" \
    --output text
}

show_instances() {
  # shellcheck disable=SC2068
  aws ec2 describe-instances --instance-ids $@ \
    --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,InstanceId,Placement.AvailabilityZone,PrivateIpAddress,State.Name]' \
    --output text | sort | column -t
}

# 아직 멈추지 않은 프로세스 이름을 ASG별로 출력합니다. 아무것도 안 나오면 전부 멈춘 상태입니다.
asg_unsuspended() {
  local asg p suspended
  for asg in $(asg_names); do
    suspended="$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$asg" \
      --query 'AutoScalingGroups[0].SuspendedProcesses[].ProcessName' --output text)"
    for p in $ASG_PROCESSES; do
      grep -qw "$p" <<< "$suspended" || echo "$asg:$p"
    done
  done
}

suspend_asgs() {
  local asg
  for asg in $(asg_names); do
    # shellcheck disable=SC2086
    aws autoscaling suspend-processes --auto-scaling-group-name "$asg" --scaling-processes $ASG_PROCESSES
    log "ASG 프로세스 중지: $asg"
  done
  [[ -z "$(asg_unsuspended)" ]] || die "일부 ASG 프로세스가 멈추지 않았습니다: $(asg_unsuspended | tr '\n' ' ')"
}

resume_asgs() {
  local asg
  for asg in $(asg_names); do
    # shellcheck disable=SC2086
    aws autoscaling resume-processes --auto-scaling-group-name "$asg" --scaling-processes $ASG_PROCESSES
    log "ASG 프로세스 재개: $asg"
  done
}

# 인스턴스들이 SSM에 Online으로 붙을 때까지 기다립니다(최대 $2초).
wait_ssm_online() {
  local ids="$1" timeout="${2:-600}" start id online missing
  start=$(date +%s)
  while :; do
    missing=""
    for id in $ids; do
      online="$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$id" \
        --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || true)"
      [[ "$online" == Online ]] || missing="$missing $id"
    done
    [[ -z "$missing" ]] && return 0
    (( $(date +%s) - start > timeout )) && die "SSM Online 대기 시간 초과:$missing"
    sleep 10
  done
}

# 여러 인스턴스에 bash 스크립트를 SSM으로 실행합니다.
# 인스턴스별 출력을 보여 주고, 하나라도 실패하면 1을 돌려줍니다.
# 사용: ssm_run "<id id ...>" "<bash 스크립트>" [timeout초]
ssm_run() {
  local ids="$1" script="$2" timeout="${3:-300}" b64 params cid id status rc=0 start
  # SSM은 명령을 sh(dash)로 실행하므로 base64로 옮긴 뒤 bash로 돌립니다.
  b64="$(printf '%s' "$script" | base64 | tr -d '\n')"
  params="$(jq -cn --arg c "echo '$b64' | base64 -d | bash" --arg t "$timeout" \
    '{commands:[$c], executionTimeout:[$t]}')"
  # shellcheck disable=SC2086
  cid="$(aws ssm send-command --instance-ids $ids --document-name AWS-RunShellScript \
    --timeout-seconds 60 --parameters "$params" \
    --query Command.CommandId --output text)"
  start=$(date +%s)
  for id in $ids; do
    while :; do
      status="$(aws ssm get-command-invocation --command-id "$cid" --instance-id "$id" \
        --query Status --output text 2>/dev/null || echo Pending)"
      case "$status" in
        Success|Failed|Cancelled|TimedOut|Undeliverable|Terminated) break ;;
      esac
      (( $(date +%s) - start > timeout + 60 )) && { status=TimedOut; break; }
      sleep 3
    done
    aws ssm get-command-invocation --command-id "$cid" --instance-id "$id" \
      --query '[StandardOutputContent,StandardErrorContent]' --output text 2>/dev/null \
      | sed '/^None$/d; /^[[:space:]]*$/d; s/^/    /'
    [[ "$status" == Success ]] || { warn "$id: SSM 명령 $status"; rc=1; }
  done
  return $rc
}

# CP에서 kubectl을 쓰는 스크립트 앞부분입니다.
KUBE_ENV='export KUBECONFIG=/etc/kubernetes/admin.conf; export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'

# CP 로컬 etcd에서 클러스터 전체 상태를 묻는 명령입니다.
ETCDCTL='CID="$(crictl --runtime-endpoint unix:///run/containerd/containerd.sock ps --name "^etcd$" -q 2>/dev/null | head -1)"
[[ -n "$CID" ]] || echo "etcd 컨테이너가 아직 없습니다" >&2
etcd() { crictl --runtime-endpoint unix:///run/containerd/containerd.sock exec "$CID" etcdctl 2>/dev/null \
  --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key "$@"; }'
