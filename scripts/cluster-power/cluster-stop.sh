#!/bin/bash
# 클러스터 EC2(CP 3대 + 워커 ASG 전체)를 안전한 순서로 중지합니다.
#
#   1) 사전 점검: CP 3대·워커 수, etcd 3대 정상, 노드 전부 Ready
#   2) etcd 스냅샷을 지금 한 번 S3에 올림(리더 CP만 올리고 나머지는 건너뜀)
#   3) 워커 ASG의 교체·종료 프로세스 중지  ← 안 하면 ASG가 중지된 워커를 지우고 새로 띄웁니다
#   4) 워커 중지 → 완료 대기
#   5) CP 중지 → 완료 대기
#
# 사용: scripts/cluster-power/cluster-stop.sh [--yes] [--skip-snapshot] [--force]
#   --yes            확인 질문 없이 진행
#   --skip-snapshot  지금 스냅샷을 만들지 않음(매시간 스냅샷은 그대로 있음)
#   --force          사전 점검이 실패해도 진행(이미 고장 난 클러스터를 끌 때만)
#
# 끄고 나서는 cluster-start.sh로 켭니다. 꺼 둔 동안 terraform apply를 돌리지 마세요
# (ASG suspended_processes가 풀릴 수 있습니다). NAT·NLB·EBS·RDS 요금은 계속 나갑니다.

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$DIR/common.sh"

ASSUME_YES=0 SKIP_SNAPSHOT=0 FORCE=0
for arg in "$@"; do
  case "$arg" in
    --yes) ASSUME_YES=1 ;;
    --skip-snapshot) SKIP_SNAPSHOT=1 ;;
    --force) FORCE=1 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) die "알 수 없는 옵션: $arg" ;;
  esac
done

preflight_fail() {
  if [[ "$FORCE" == 1 ]]; then warn "$1 (--force라 계속 진행)"; else die "$1 (--force로 무시 가능)"; fi
}

check_tools

CPS="$(cp_ids)"
WORKERS="$(worker_ids)"
CP_COUNT=$(wc -w <<< "$CPS" | tr -d ' ')
WORKER_COUNT=$(wc -w <<< "$WORKERS" | tr -d ' ')
DESIRED=$(desired_total)

log "대상 계정 $(aws sts get-caller-identity --query Account --output text), 리전 $AWS_REGION"
log "CP ${CP_COUNT}대, 워커 ${WORKER_COUNT}대 (ASG desired 합계 $DESIRED)"
# shellcheck disable=SC2086
show_instances $CPS $WORKERS

[[ "$CP_COUNT" == "$EXPECTED_CP" ]] || preflight_fail "CP가 ${EXPECTED_CP}대가 아닙니다."
[[ "$WORKER_COUNT" == "$DESIRED" ]] || preflight_fail "워커 수와 ASG desired 합계가 다릅니다(교체 중일 수 있음)."

# shellcheck disable=SC2086
RUNNING_CPS="$(aws ec2 describe-instances --instance-ids $CPS \
  --filters Name=instance-state-name,Values=running --query 'Reservations[].Instances[].InstanceId' --output text)"

if [[ -n "$RUNNING_CPS" ]]; then
  FIRST_CP="${RUNNING_CPS%%[[:space:]]*}"
  log "사전 점검: etcd·노드 상태"
  if ! ssm_run "$FIRST_CP" "$KUBE_ENV
$ETCDCTL
set -e
etcd endpoint health --cluster
kubectl get nodes --no-headers | awk '{print \"    \" \$1, \$2}'
NOT_READY=\$(kubectl get nodes --no-headers | awk '\$2 != \"Ready\"' | wc -l)
[[ \$NOT_READY == 0 ]] || { echo \"Ready가 아닌 노드 \$NOT_READY대\"; exit 1; }" 180; then
    preflight_fail "etcd 또는 노드 상태가 정상이 아닙니다."
  fi

  if [[ "$SKIP_SNAPSHOT" == 0 ]]; then
    log "etcd 스냅샷을 S3에 올립니다(리더 CP만 업로드)."
    # shellcheck disable=SC2086
    ssm_run "$RUNNING_CPS" 'set -e
systemctl start mulo-etcd-snapshot.service
journalctl -u mulo-etcd-snapshot.service -n 3 --no-pager -o cat' 600 \
      || preflight_fail "etcd 스냅샷 실패."
  fi
else
  warn "실행 중인 CP가 없어 etcd 점검과 스냅샷을 건너뜁니다."
fi

confirm "위 인스턴스를 모두 중지합니다(워커 → CP 순서)."

log "1/3 워커 ASG 프로세스 중지: $ASG_PROCESSES"
suspend_asgs

if [[ -n "$WORKERS" ]]; then
  log "2/3 워커 ${WORKER_COUNT}대 중지"
  # shellcheck disable=SC2086
  aws ec2 stop-instances --instance-ids $WORKERS --query 'StoppingInstances[].[InstanceId,CurrentState.Name]' --output text
  # shellcheck disable=SC2086
  aws ec2 wait instance-stopped --instance-ids $WORKERS
  log "워커 중지 완료"
fi

log "3/3 CP ${CP_COUNT}대 중지"
# shellcheck disable=SC2086
aws ec2 stop-instances --instance-ids $CPS --query 'StoppingInstances[].[InstanceId,CurrentState.Name]' --output text
# shellcheck disable=SC2086
aws ec2 wait instance-stopped --instance-ids $CPS
log "CP 중지 완료"

# ASG가 중지된 워커를 교체하지 않았는지 마지막으로 확인합니다.
AFTER="$(worker_ids)"
[[ "$(wc -w <<< "$AFTER" | tr -d ' ')" == "$WORKER_COUNT" ]] \
  || warn "ASG 인스턴스 목록이 바뀌었습니다. 콘솔에서 새로 뜬 인스턴스가 있는지 확인하세요."

# shellcheck disable=SC2086
show_instances $CPS $AFTER
log "완료. 켤 때는 scripts/cluster-power/cluster-start.sh 를 실행하세요. 꺼 둔 동안 terraform apply 금지."
