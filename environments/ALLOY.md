# AI·backend·chat Docker 로그 수집

staging·prod의 앱 부팅 스크립트는 Grafana apt 저장소에서 Alloy를 설치하고 Docker stdout·stderr 로그를 해당 환경의 Loki로 전송합니다. frontend에는 Alloy를 설치하지 않습니다.

| 환경 | Loki push 주소 | 로그 environment 라벨 |
| --- | --- | --- |
| staging | `http://10.21.0.2:3100/loki/api/v1/push` | `staging` |
| prod | `http://10.20.0.2:3100/loki/api/v1/push` | `prod` |

주소는 현재 예약 IP 기준이며 코드에서는 `google_compute_address.monitoring_internal.address`를 참조합니다. IP를 직접 하드코딩하지 않습니다. 앱 VM → 모니터링 VM의 TCP 3100 방화벽은 기존 설정을 사용합니다.

## 부팅 동작

- 템플릿의 `alloy-service`, `alloy-environment`, `alloy-loki-url` 메타데이터를 읽습니다. 서비스 값은 `ai`·`backend`·`chat`입니다.
- 기존 `/var/lib/mulo-setup-done` 파일이 있어도 Alloy 설치 여부를 별도로 확인합니다. 패키지가 있으면 재설치는 생략합니다.
- 매 부팅마다 `/etc/alloy/config.alloy`를 생성하고 `alloy validate`를 통과한 파일만 반영합니다.
- `alloy` 사용자를 `docker` 그룹에 추가하고 systemd에서 Docker 이후 Alloy를 시작합니다. Alloy는 부팅 시 자동 시작되며 설정 반영 후 재시작합니다.
- `job="docker-logs"`, 환경, 서비스, VM 호스트명, Docker 컨테이너 이름을 라벨로 붙입니다. `app`과 `node-exporter` 등 발견한 컨테이너를 수집합니다.
- Chat 앱 이미지가 없어도 Alloy 설치는 실행합니다. Loki의 `/ready` 확인이 실패하면 경고를 남기고 앱 부팅을 계속합니다.
- Alloy 설정은 엄격 모드의 별도 Bash 프로세스에서 수행합니다. 메타데이터 조회·패키지 설치·설정 검증·서비스 재시작이 실패해도 부모 스크립트는 경고를 남기고 앱 시작을 계속합니다. 실패한 Alloy 설치는 부팅 로그에서 확인하고 재시도해야 합니다.

설치와 설정 검증은 [Grafana Linux 설치 문서](https://grafana.com/docs/alloy/latest/set-up/install/linux/), [Alloy validate 문서](https://grafana.com/docs/alloy/latest/reference/cli/validate/)를 따릅니다.

## 기존 VM에 반영할 때

`terraform plan`은 설치를 실행하지 않습니다. `terraform apply`로 템플릿을 갱신하더라도 기존 VM에 즉시 설치되는지는 MIG 정책에 따라 다릅니다.

- **staging**: MIG의 새 템플릿 참조는 갱신되지만 `OPPORTUNISTIC` 정책이므로 기존 VM을 자동 교체하지 않습니다. 이후 새 템플릿으로 생성·명시적 재생성한 VM에서 설치됩니다. 기존 VM을 단순 재부팅하면 이전 메타데이터와 스크립트를 사용하므로 새 설정으로 전환되지 않습니다.
- **prod**: `ignore_changes = [version]`을 유지하므로 Terraform 기반 템플릿만 교체하고 현재 CD 템플릿을 쓰는 MIG는 갱신하지 않습니다. 현재 배포 이미지·태그를 입력값에 맞춘 뒤 [부팅 템플릿 전환 안내](BOOTSTRAP.md#3-terraform과-cd가-공유하는-값)에 따라 version 무시를 잠시 해제해 새 계획을 만들거나, CD가 사용하는 템플릿에 새 스크립트와 Alloy 메타데이터를 함께 반영해야 합니다. 현재 저장한 plan만 적용하면 운영 VM에 Alloy가 설치되지는 않습니다.

부팅 스크립트는 frontend와 공유하므로 frontend의 인스턴스 템플릿도 교체 대상으로 표시됩니다. frontend에는 Alloy 메타데이터가 없어 설치 단계는 건너뜁니다.

## 2026-10-21 plan 확인

양쪽 환경에서 기존 GCS state와 로컬 `terraform.tfvars`를 사용해 전체 plan을 실행했습니다. 적용은 실행하지 않았습니다.

| 환경 | 추가 | 변경 | 삭제 | 대상 |
| --- | ---: | ---: | ---: | --- |
| staging | 4 | 4 | 4 | 앱 템플릿 4개 교체, MIG 4개의 템플릿 참조 갱신 |
| prod | 4 | 0 | 4 | 앱 템플릿 4개 교체 |

삭제 4개는 기존 인스턴스 템플릿입니다. 실제 VM·DB·Redis·모니터링 VM·네트워크·방화벽의 생성·변경·삭제는 없습니다. 앱 이미지·태그 변경도 없습니다.

각 환경 폴더에 `tfplan-alloy`와 상세 검토용 `tfplan-alloy.json`을 저장했습니다. plan은 해당 시점의 상태 기준이며 실제 반영 방식을 변경한 뒤에는 다시 생성합니다. `terraform fmt -check -recursive`, 양쪽 `terraform validate`, 부팅 스크립트의 `bash -n` 검증을 통과했습니다. VM 안에서의 설치·Loki 수신 여부는 아직 검증하지 않았습니다.

추가로 공식 Alloy v1.21.0의 macOS 바이너리와 릴리스 SHA-256을 확인해, 양쪽 환경의 AI·backend·chat 설정 6개를 실제 `alloy validate`로 검증했습니다. 로컬 모의 실행 14건으로 정상 설정 6건, frontend 제외, 메타데이터 조회 실패, 불완전한 메타데이터, 패키지 설치 실패, 설정 검증 실패, Alloy 재시작 실패, 비활성 서비스, Loki 준비 실패 상황에서 앱 시작 경로가 유지되는 것도 확인했습니다. 모의 실행은 호스트 변경 명령을 대체했으며 실제 apt 설치나 Linux systemd 기동 검증은 아닙니다.

## 같은 날 기존 서비스 상태 조회

이 조회는 새 코드를 배포한 결과가 아닙니다. `apply`, VM 전원 변경, 컨테이너 재시작, 패키지 설치는 실행하지 않았습니다.

| 운영 VM | 기존 앱 이미지 태그 | 앱 컨테이너 | 로컬 앱 헬스체크 |
| --- | --- | --- | --- |
| AI `fgd2` | `1.10.0` | 실행 중 | 200 |
| AI `mr16` | `1.10.0` | 실행 중 | 200 |
| backend `6w6m` | `1.12.0` | 실행 중 | 200 |
| chat `r53g` | `1.0.3` | 실행 중 | 200 |

각 VM의 Node Exporter도 실행 중이었으며 Alloy는 비활성이었습니다. 네 VM에서 조회한 운영 Loki `/ready`는 모두 503이었으므로 로그 수신 정상 여부를 확인한 상태가 아닙니다. 운영 Redis는 `TERMINATED`, staging 앱·모니터링·Redis VM도 모두 `TERMINATED`였습니다. 현재 계획은 이 전원 상태를 변경하지 않습니다. 앱 헬스체크 200만으로 Redis 연동 등을 포함한 전체 기능을 보장하지는 않습니다.

운영 Terraform 기반 템플릿의 입력 태그는 AI `1.5.0`, backend `1.7.0`, chat `1.0.0`으로 현재 CD 배포 태그보다 오래됐습니다. 현재 plan은 MIG version을 무시하므로 앱 이미지를 바꾸지 않지만, **이 상태에서 version 무시만 해제하면 과거 이미지로 교체될 수 있습니다.** 실제 전환 전에 현재 배포 이미지·태그를 먼저 맞추고 새 plan에서 비교해야 합니다.

## 반영 후 VM 안에서 확인

```bash
sudo systemctl status alloy --no-pager
sudo journalctl -u alloy -n 50 --no-pager
sudo cat /etc/alloy/config.alloy
id alloy
# staging은 10.21.0.2, prod는 10.20.0.2
curl --fail --connect-timeout 3 --max-time 5 http://10.21.0.2:3100/ready
```

Grafana Explore에서 예를 들어 `{job="docker-logs", environment="staging", service="backend"}`로 로그 수신을 확인합니다.
