# 클러스터 끄기·켜기

CP 3대와 워커 ASG 인스턴스 전체를 중지했다가 다시 켜는 스크립트입니다. 기본 프로필은 `mulo-prod`이고, `AWS_PROFILE`로 바꿀 수 있습니다.

```bash
scripts/cluster-power/cluster-stop.sh           # 점검 → etcd 스냅샷 → ASG 프로세스 중지 → 워커 중지 → CP 중지
scripts/cluster-power/cluster-start.sh          # CP 시작 → etcd·API 확인 → 워커 시작 → 노드·Pod·Vault 확인 → ASG 재개
scripts/cluster-power/cluster-start.sh --check  # 아무것도 바꾸지 않고 상태 점검만
```

## 왜 그냥 끄면 안 되나

워커는 ASG(상태 검사 `EC2`)에 들어 있습니다. ASG는 중지된 인스턴스를 비정상으로 보고 종료한 뒤 새로 띄웁니다. 그래서 끄기 전에 `Launch Terminate HealthCheck ReplaceUnhealthy AZRebalance InstanceRefresh ScheduledActions` 프로세스를 멈추고, 켠 뒤 모든 점검을 통과하면 다시 재개합니다.

## 주의

- 꺼 둔 동안 `terraform apply`를 돌리지 않습니다. ASG의 suspended_processes가 풀리면 중지된 워커가 교체됩니다.
- 켜기 점검이 실패하면 ASG 프로세스는 멈춘 채로 둡니다. 원인을 고친 뒤 `cluster-start.sh --resume-asg-only`로 재개합니다.
- CP의 `/var/lib/etcd`는 fstab에 `nofail`로 등록돼 있고, kubelet drop-in(`RequiresMountsFor=/var/lib/etcd`)이 마운트 없이는 kubelet을 시작하지 않게 막습니다. 켜기 스크립트는 3대 모두 마운트됐는지 확인한 뒤에 진행합니다. 자세한 내용은 [docs/etcd-volume](../../docs/etcd-volume/README.md)에 있습니다.
- EC2를 꺼도 NAT Gateway, NLB, EBS, RDS 요금은 계속 나갑니다.
