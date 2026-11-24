#!/bin/bash
# cluster-stop.sh로 끈 클러스터를 다시 켭니다.
#
#   1) CP 3대를 동시에 켬(etcd는 3대 중 2대가 떠야 동작) → SSM 연결 대기
#   2) CP마다 /var/lib/etcd 마운트·kubelet 확인 → etcd 3대 정상·API 서버 ready 대기
#   3) 워커 켬 → 노드 전부 Ready 대기
#   4) Vault unseal 상태·Running이 아닌 Pod 확인
#   5) 전부 정상이면 워커 ASG 프로세스 재개
#
# 사용: scripts/cluster-power/cluster-start.sh [--yes] [--resume-asg-only] [--check]
#   --yes              확인 질문 없이 진행
#   --resume-asg-only  켜기는 건너뛰고 ASG 프로세스만 재개(앞서 점검 실패로 재개를 미뤘을 때)
#   --check            인스턴스·ASG는 건드리지 않고 2)~4) 점검만 실행(켜져 있는 클러스터 상태 확인용)

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$DIR/common.sh"

ASSUME_YES=0 RESUME_ONLY=0 CHECK_ONLY=0
NODE_TIMEOUT="${NODE_TIMEOUT:-900}"   # 노드 Ready 대기(초)
POD_TIMEOUT="${POD_TIMEOUT:-600}"     # Pod 정상화 대기(초)
for arg in "$@"; do
  case "$arg" in
    --yes) ASSUME_YES=1 ;;
    --resume-asg-only) RESUME_ONLY=1 ;;
    --check) CHECK_ONLY=1 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) die "알 수 없는 옵션: $arg" ;;
  esac
done

check_tools

if [[ "$RESUME_ONLY" == 1 ]]; then
  confirm "워커 ASG 프로세스를 재개합니다. 중지·비정상 워커가 있으면 ASG가 교체합니다."
  resume_asgs
  exit 0
fi

CPS="$(cp_ids)"
WORKERS="$(worker_ids)"
CP_COUNT=$(wc -w <<< "$CPS" | tr -d ' ')
WORKER_COUNT=$(wc -w <<< "$WORKERS" | tr -d ' ')
TOTAL_NODES=$((CP_COUNT + WORKER_COUNT))

log "대상 계정 $(aws sts get-caller-identity --query Account --output text), 리전 $AWS_REGION"
log "CP ${CP_COUNT}대, 워커 ${WORKER_COUNT}대"
# shellcheck disable=SC2086
show_instances $CPS $WORKERS
[[ "$CP_COUNT" == "$EXPECTED_CP" ]] || die "CP가 ${EXPECTED_CP}대가 아닙니다."

UNSUSPENDED="$(asg_unsuspended)"
if [[ "$CHECK_ONLY" == 1 ]]; then
  log "--check: 인스턴스 시작과 ASG 변경 없이 점검만 합니다."
elif [[ -n "$UNSUSPENDED" ]]; then
  warn "ASG 프로세스 일부가 멈춰 있지 않습니다: $(tr '\n' ' ' <<< "$UNSUSPENDED")"
  warn "중지된 워커가 이미 교체됐을 수 있습니다. 켜는 동안 교체되지 않게 지금 다시 멈춥니다."
fi

if [[ "$CHECK_ONLY" == 0 ]]; then
  confirm "CP를 먼저 켜고, etcd·API가 정상이면 워커를 켭니다."
  [[ -n "$UNSUSPENDED" ]] && suspend_asgs

  # ---------- 1) CP ----------
  log "1/5 CP ${CP_COUNT}대 시작"
  # shellcheck disable=SC2086
  aws ec2 start-instances --instance-ids $CPS --query 'StartingInstances[].[InstanceId,CurrentState.Name]' --output text
  # shellcheck disable=SC2086
  aws ec2 wait instance-running --instance-ids $CPS
  log "CP running. SSM 연결 대기"
fi
wait_ssm_online "$CPS" 600

# ---------- 2) etcd·API ----------
log "2/5 CP 디스크·kubelet 확인"
# kubelet drop-in(RequiresMountsFor=/var/lib/etcd) 때문에 마운트가 없으면 kubelet이 안 뜹니다.
# 여기서 마운트가 없으면 etcd EBS 연결 문제이므로 멈추고 사람이 봐야 합니다.
ssm_run "$CPS" 'mountpoint -q /var/lib/etcd || { echo "$(hostname): /var/lib/etcd 마운트 안 됨"; exit 1; }
for i in $(seq 1 30); do systemctl is-active --quiet kubelet && break; sleep 5; done
echo "$(hostname): etcd 볼륨 $(findmnt -no SOURCE /var/lib/etcd), kubelet $(systemctl is-active kubelet)"
systemctl is-active --quiet kubelet' 240 \
  || die "CP 디스크 또는 kubelet 이상. 워커는 켜지 않았습니다. 해당 CP에서 journalctl -u kubelet, lsblk를 확인하세요."

FIRST_CP="${CPS%%[[:space:]]*}"
log "etcd 3대 정상·API 서버 ready 대기(최대 10분)"
ssm_run "$FIRST_CP" "$KUBE_ENV
for i in \$(seq 1 60); do
  $ETCDCTL
  if etcd endpoint health --cluster >/tmp/etcd-health 2>&1 && [[ \$(grep -c 'is healthy' /tmp/etcd-health) == $EXPECTED_CP ]] \\
     && kubectl get --raw=/readyz >/dev/null 2>&1; then
    cat /tmp/etcd-health; echo 'API readyz ok'; exit 0
  fi
  sleep 10
done
cat /tmp/etcd-health; exit 1" 720 \
  || die "etcd 또는 API 서버가 정상이 되지 않았습니다. 워커는 켜지 않았습니다."

# ---------- 3) 워커 ----------
if [[ -n "$WORKERS" && "$CHECK_ONLY" == 0 ]]; then
  log "3/5 워커 ${WORKER_COUNT}대 시작"
  # shellcheck disable=SC2086
  aws ec2 start-instances --instance-ids $WORKERS --query 'StartingInstances[].[InstanceId,CurrentState.Name]' --output text
  # shellcheck disable=SC2086
  aws ec2 wait instance-running --instance-ids $WORKERS
fi

log "노드 ${TOTAL_NODES}대 Ready 대기(최대 $((NODE_TIMEOUT / 60))분)"
NODES_OK=1
ssm_run "$FIRST_CP" "$KUBE_ENV
for i in \$(seq 1 $((NODE_TIMEOUT / 15))); do
  READY=\$(kubectl get nodes --no-headers 2>/dev/null | awk '\$2 == \"Ready\"' | wc -l)
  [[ \$READY -ge $TOTAL_NODES ]] && { kubectl get nodes; exit 0; }
  sleep 15
done
kubectl get nodes; exit 1" $((NODE_TIMEOUT + 60)) || NODES_OK=0

# ---------- 4) 워크로드 ----------
log "4/5 Vault·Pod 상태 확인(최대 $((POD_TIMEOUT / 60))분)"
PODS_OK=1
ssm_run "$FIRST_CP" "$KUBE_ENV
for i in \$(seq 1 $((POD_TIMEOUT / 15))); do
  BAD=\$(kubectl get pods -A --no-headers 2>/dev/null | awk '\$4 != \"Running\" && \$4 != \"Completed\"' | wc -l)
  NOTREADY=\$(kubectl get pods -A --no-headers 2>/dev/null | awk '\$4 == \"Running\" { split(\$3, r, \"/\"); if (r[1] != r[2]) print }' | wc -l)
  [[ \$BAD == 0 && \$NOTREADY == 0 ]] && break
  sleep 15
done
echo '[Vault]'
kubectl -n vault exec vault-0 -c vault -- vault status 2>&1 | grep -E 'Seal Type|Sealed|HA Mode' || true
SEALED=\$(kubectl -n vault exec vault-0 -c vault -- vault status -format=json 2>/dev/null | jq -r .sealed)
echo '[정상이 아닌 Pod]'
kubectl get pods -A --no-headers | awk '(\$4 != \"Running\" && \$4 != \"Completed\") || (\$4 == \"Running\" && split(\$3, r, \"/\") && r[1] != r[2])'
[[ \$SEALED == false && \$BAD == 0 && \$NOTREADY == 0 ]]" $((POD_TIMEOUT + 120)) || PODS_OK=0

# ---------- 5) ASG ----------
if [[ "$CHECK_ONLY" == 1 ]]; then
  [[ "$NODES_OK" == 1 && "$PODS_OK" == 1 ]] && { log "점검 통과"; exit 0; }
  warn "점검 실패: 위 출력을 확인하세요."; exit 1
elif [[ "$NODES_OK" == 1 && "$PODS_OK" == 1 ]]; then
  log "5/5 워커 ASG 프로세스 재개"
  resume_asgs
  log "완료. 클러스터가 정상으로 돌아왔습니다."
else
  warn "노드 또는 Pod가 아직 정상이 아니라 ASG 프로세스를 재개하지 않았습니다."
  warn "원인을 확인한 뒤 scripts/cluster-power/cluster-start.sh --resume-asg-only 로 재개하세요."
  warn "재개하지 않으면 워커가 죽어도 ASG가 교체하지 않습니다."
  exit 1
fi
