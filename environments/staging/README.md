# 스테이징 환경

운영과 같은 서비스 배치로 앱 연결과 롤링 배포를 검증하는 환경입니다. 앱은 MIG 4개로 관리하고, DB·이미지 버킷·네트워크는 스테이징 전용으로 생성합니다.

[공통 요청 흐름](../README.md#스테이징운영의-요청-흐름) · [루트 모듈](main.tf) · [리소스 정의](../../modules/staging_modules)

## VM 구성

| 용도 | 관리 방식 | 수량 | 기본 사양 |
| --- | --- | --- | --- |
| frontend | MIG | 1대 | `e2-medium`, 20GB |
| backend | MIG | 1대 | `e2-medium`, 20GB |
| AI | MIG | 2대 | 각 `e2-medium`, 20GB |
| chat | MIG | 1대 | `e2-medium`, 20GB |
| Redis | 독립 VM | 1대 | `e2-small`, 20GB |
| 모니터링 | 독립 VM | 1대 | `e2-medium`, 30GB |

총 VM 7대이며 모두 Ubuntu 22.04를 사용합니다. 앱 VM은 내부 IP를 자동 할당받고, Redis와 모니터링은 고정 내부 IP를 사용합니다. Redis와 모니터링은 앱 롤링 배포 대상에서 제외됩니다.

## 요청이 들어오는 경로

사용자 요청은 **HTTPS LB → 경로에 해당하는 앱 MIG → 서비스 VM** 순서로 전달됩니다. AI 요청은 2대의 VM을 대상으로 분산합니다. 라우팅·포트·헬스체크는 [공통 경로 표](../README.md#스테이징운영의-요청-흐름)에 정리되어 있습니다.

전용 VPC의 서브넷은 기본 `10.21.0.0/24`, 리소스 접두사는 `mulo-v2-staging`입니다. VM의 외부 통신은 Cloud NAT, SSH 접속은 IAP를 사용합니다. LB의 연결 드레이닝은 **60초**, 요청 로그는 비활성화되어 있습니다.

## 데이터 구성

| 서비스 | Cloud SQL 인스턴스 | 버전 | DB 이름 |
| --- | --- | --- | --- |
| backend | `mulo-v2-staging-mysql-be` | MySQL 8.4 | `mulo` |
| chat | `mulo-v2-staging-mysql-chat` | MySQL 8.4 | `mulo_chat` |
| AI | `mulo-v2-staging-postgres-ai` | PostgreSQL 18 | `mulo_ai` |

인스턴스 이름은 기본 접두사 기준입니다. DB 3대는 모두 사설 IP를 사용하며 기본 사양은 `db-g1-small`, 20GB입니다. 자동 백업·binlog·PITR·디스크 자동 확장은 꺼져 있습니다.

이미지는 별도 비공개 GCS 버킷에 저장하고 backend에 객체 관리 권한을 부여합니다. Redis 연결은 앱 VM에서 Redis 고정 IP의 6379 포트로 허용됩니다. Redis 설치와 Compose 구성은 직접 담당합니다.

Cloud Tasks는 `mulo-v2-staging-ai-task` 큐와 OIDC용 계정을 생성합니다. backend가 작업을 등록하고 AI가 처리하는 흐름이며, 실제 작업 URL·권한·토큰 검증은 앱과 IAM 설정에서 구성합니다.

## VM 관리

[bootstrap.sh](bootstrap.sh)가 Docker·Compose 등 기본 실행 환경을 준비합니다. 앱·Redis·모니터링 스택은 직접 배포하며, MIG의 새 VM에도 앱 설정이 필요합니다. 롤링 교체 방식은 [공통 MIG 설명](../README.md#앱-mig의-동작)을 참고하세요.

앱 VM의 전원은 [mig-power.sh](mig-power.sh), 독립 모니터링·Redis VM과 Cloud SQL의 실행 상태는 `runtime_enabled`가 담당합니다.

### mig-power.sh 사용

저장소 루트에서 스테이징 폴더로 이동한 뒤 필요한 명령을 실행합니다. `gcloud` 인증 계정에 해당 MIG의 중지·시작 권한이 있어야 합니다.

```bash
cd environments/staging
```

| 명령 | 동작 |
| --- | --- |
| `./mig-power.sh status` | 앱 VM의 전원 상태와 진행 중인 작업 확인 |
| `./mig-power.sh stop` | 앱 VM 5대 중지 |
| `./mig-power.sh start` | 중지된 앱 VM 다시 시작 |

대상은 frontend·backend·chat 각 1대와 AI 2대입니다. VM과 디스크를 유지한 채 전원을 변경하며, 모니터링·Redis·Cloud SQL은 이 명령의 대상이 아닙니다.

중지는 LB 연결 드레이닝과 VM 종료 때문에 시간이 걸릴 수 있습니다. 대기 중에는 30초마다 진행 상황을 표시합니다. `start` 완료는 VM이 켜졌다는 뜻이며 앱의 헬스체크 상태는 별도로 확인합니다.

### 스테이징 전체 중지와 시작

`terraform.tfvars`의 `runtime_enabled`는 모니터링·Redis VM과 Cloud SQL 3대를 함께 제어합니다. `false`는 중지, `true`는 실행이며, 값을 바꾼 뒤 Terraform으로 적용해야 반영됩니다. 아래 명령은 모두 `environments/staging`에서 실행합니다.

**중지할 때** 앱 VM을 먼저 중지하고, `terraform.tfvars`의 기존 `runtime_enabled` 값을 `false`로 바꿉니다.

```bash
./mig-power.sh stop
# terraform.tfvars에서 runtime_enabled = false로 변경
terraform plan -out=tfplan
terraform apply tfplan
./mig-power.sh status
```

**다시 켤 때** GCP 콘솔에서 위 데이터 구성 표의 Cloud SQL 3대를 먼저 시작하고 `RUNNABLE` 상태를 확인합니다. 중지된 DB 내부를 Terraform이 조회하면 오류가 날 수 있기 때문입니다. 그다음 `terraform.tfvars`의 `runtime_enabled`를 `true`로 바꾸고 모니터링·Redis를 시작한 뒤 앱 VM을 켭니다.

```bash
# terraform.tfvars에서 runtime_enabled = true로 변경
terraform plan -out=tfplan
terraform apply tfplan
./mig-power.sh start
./mig-power.sh status
```

## 주요 출력값

| 출력 | 내용 |
| --- | --- |
| `load_balancer_ip`, `site_url` | 외부 접속 주소 |
| `mig_names`, `instance_template_names` | 앱 MIG와 템플릿 이름 |
| `mysql_private_ips`, `postgres_private_ip` | DB 사설 주소 |
| `redis_private_ip`, `redis_port` | Redis 연결 주소·포트 |
| `monitoring_vm_name`, `monitoring_vm_private_ip` | 모니터링 VM 이름·주소 |
| `image_bucket_name`, `ai_tasks_queue_id` | 이미지 버킷과 AI 작업 큐 |
