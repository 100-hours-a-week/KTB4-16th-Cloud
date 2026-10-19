# 스테이징 환경

운영과 같은 서비스 배치로 앱 연결을 검증하는 환경입니다. 앱은 MIG 4개로 관리하고, DB·이미지 버킷·네트워크는 스테이징 전용으로 생성합니다. 스테이징에서는 자동 롤링 교체와 앱 헬스체크 실패에 따른 VM 자동 재생성을 사용하지 않습니다.

최초 VM 생성 전에 서비스별 시크릿·env와 이미지 태그를 준비합니다. 기존 VM의 앱 실행과 설정 반영은 아래 VM 관리 절차를 사용합니다.

[공통 요청 흐름](../README.md#스테이징운영의-요청-흐름) · [루트 모듈](main.tf) · [리소스 정의](../../modules/staging_modules)

## VM 구성

| 용도 | 관리 방식 | 수량 | 기본 사양 |
| --- | --- | --- | --- |
| frontend | MIG | 1대 | `e2-medium`, 20GB |
| backend | MIG | 1대 | `e2-medium`, 20GB |
| AI | MIG | 2대 | 각 `e2-medium`, 20GB |
| chat | MIG | 1대 | `e2-medium`, 20GB |
| Redis | 독립 VM | 1대 | `e2-medium`, 20GB |
| 모니터링 | 비관리형 인스턴스 그룹의 기존 VM | 1대 | `e2-medium`, 30GB |

총 VM 7대이며 모두 Ubuntu 22.04를 사용합니다. 앱 VM은 내부 IP를 자동 할당받고, Redis와 모니터링은 고정 내부 IP를 사용합니다.

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

backend와 AI에는 각 서비스 계정 자기 자신에 대한 `roles/iam.serviceAccountTokenCreator`를 부여해 키 파일 없이 GCS 서명 URL을 생성합니다. 콘솔에서 먼저 부여한 두 권한은 [import 블록](imports.tf)으로 이 환경의 상태에 연결합니다.

Cloud Tasks는 `mulo-v2-staging-ai-task` 큐와 OIDC용 계정을 생성합니다. backend가 작업을 등록하고 AI가 처리하는 흐름이며, 실제 작업 URL·권한·토큰 검증은 앱과 IAM 설정에서 구성합니다.

## VM 관리

[bootstrap.sh](bootstrap.sh)는 최초에 Docker·Google Cloud CLI·Ops Agent와 스왑을 준비하고, 매 부팅마다 이미지와 Secret Manager의 env로 앱을 실행합니다. Node Exporter도 자동으로 실행합니다. Redis·모니터링은 [base-bootstrap.sh](base-bootstrap.sh)의 기존 설치 방식을 유지하며 서비스는 직접 관리합니다.

부팅 스크립트의 상세 동작은 [앱 부팅 안내](../BOOTSTRAP.md)를 참고합니다. 공통 문서의 자동 롤링 배포 절차는 스테이징에 적용하지 않습니다.

앱 VM의 전원은 [mig-power.sh](mig-power.sh), 독립 모니터링·Redis VM과 Cloud SQL의 실행 상태는 `runtime_enabled`가 담당합니다.

### 자동 교체 없는 템플릿 관리

[compute.tf](../../modules/staging_modules/compute.tf)의 앱 MIG는 `OPPORTUNISTIC` 정책을 사용합니다. `service_image_tags`나 앱 디스크 크기를 바꾸면 Terraform이 새 템플릿을 만들고 MIG의 참조를 갱신하지만, 실행 중인 VM을 자동 교체하거나 재시작하지 않습니다. 새 설정은 이후 생성하거나 명시적으로 재생성한 VM에 적용됩니다.

HTTP 헬스체크 실패에 대한 자동 복구는 `on_failed_health_check = "DO_NOTHING"`으로 설정합니다. 헬스체크와 LB 라우팅은 유지되며, 비정상 앱의 복구는 직접 진행해야 합니다. VM 자체의 장애 복구는 `default_action_on_failure = "REPAIR"`로 유지합니다. 이 값을 `DO_NOTHING`으로 설정하면 GCP가 MIG의 중지·일시중지를 허용하지 않아 `mig-power.sh stop`이 실패합니다. `terraform apply`는 기존 VM에서 부팅 스크립트를 다시 실행하지 않습니다.

MIG의 `version`은 `ignore_changes`에 추가하지 않습니다. 이전 템플릿 참조를 유지하면 `already being used` 오류로 템플릿 삭제가 실패할 수 있습니다. 전원 관리용 `target_size`, `target_stopped_size`만 무시합니다.

정책 변경을 적용할 때는 `environments/staging`에서 이전 계획 대신 새 계획을 만듭니다.

```bash
terraform plan -out=tfplan
terraform apply tfplan
```

이미 시작된 개별 VM의 생성·삭제 작업은 정책을 바꿔도 취소되지 않을 수 있습니다.

### 기존 VM에서 시크릿 수정 반영

기존 VM의 메타데이터에 설정된 이미지를 그대로 사용하고 최신 env 시크릿만 다시 읽으려면 해당 VM에서 다음 명령을 실행합니다. 부팅 스크립트가 앱 컨테이너를 다시 만들므로 잠시 서비스가 중단될 수 있습니다.

```bash
sudo systemctl restart google-startup-scripts.service
sudo journalctl -u google-startup-scripts.service -n 100 --no-pager
sudo docker ps -a
```

이미지 태그를 Terraform에서 바꿔도 기존 VM의 메타데이터는 갱신되지 않습니다. 위 명령만으로 새 템플릿의 태그가 기존 VM에 적용되지는 않습니다.

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

실행 중인 앱 VM이 0대여도 중지된 VM은 MIG에 남아 있습니다. `resize --size=0`은 VM과 앱 디스크를 삭제하므로 전원 중지 명령으로 사용하지 않습니다.

중지는 LB 연결 드레이닝과 VM 종료 때문에 시간이 걸릴 수 있습니다. 대기 중에는 상태가 바뀌거나 30초가 지날 때 진행 상황을 표시합니다. `start` 완료는 VM이 켜졌다는 뜻이며 앱의 헬스체크 상태는 별도로 확인합니다.

### 스테이징 전체 중지와 시작

다음 명령은 앱 부팅 스크립트와 서비스별 env 시크릿이 준비된 환경 기준입니다.

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

## 모니터링 도메인 접속

설정 파일 전체와 청크·Ruler·링·TSDB·보관기간 처리의 의미는 [스테이징 모니터링 구성과 용어 설명](../../docs/스테이징-모니터링-구성.md)을 참고합니다.

기존 모니터링 VM을 `google_compute_instance_group.monitoring` 비관리형 그룹에 등록하고, 기존 외부 HTTPS LB에 Grafana·Prometheus 백엔드를 추가합니다. VM·디스크·고정 내부 IP는 그대로 사용합니다.

| 서비스 | 기본 주소 | VM 수신 포트 | 헬스체크 |
| --- | --- | --- | --- |
| Grafana | `https://grafana.mulostudio.p-e.kr` | 3000 | `/api/health` |
| Prometheus | `https://prometheus.mulostudio.p-e.kr` | 9090 | `/-/ready` |

주소는 이 환경의 `domain`에 서비스 이름을 붙여 생성합니다. 실제 VM의 공개 포트가 다르면 `terraform.tfvars`의 `monitoring_ports = { grafana = 3000, prometheus = 9090 }`으로 조정합니다. 방화벽은 Google LB·헬스체크 주소에서 이 두 포트로 들어오는 TCP만 허용하고, Loki 3100 포트는 외부 LB에 연결하지 않습니다.

1. VM에서 Grafana·Prometheus를 실행하고 VM 내부 IP 또는 `0.0.0.0`의 해당 포트에 바인딩합니다. Docker Compose 사용 시 VM 포트로 publish해야 합니다. Terraform은 두 서비스를 설치하거나 Compose 설정을 변경하지 않습니다.
2. Grafana의 `GF_SERVER_ROOT_URL`을 `terraform output -json monitoring_urls`의 Grafana 주소에 맞춥니다. Prometheus의 `--web.external-url`도 해당 HTTPS 주소로 맞춥니다. TLS는 LB에서 종료하고 VM에는 HTTP로 전달합니다.
3. `terraform plan -out=monitoring.tfplan`으로 VM·디스크 교체가 없는지 확인하고 검토한 계획을 적용합니다.
4. `terraform output -json monitoring_dns_records`에 나온 두 A 레코드를 외부 DNS에 등록합니다. DNS는 이 저장소에서 관리하지 않습니다. 동일 호스트에 AAAA 레코드가 있으면 이 LB의 주소와 일치하는지도 확인합니다.
5. 서비스별 Google 관리 인증서가 `ACTIVE`이고 백엔드가 `HEALTHY`인 것을 확인한 뒤 위 HTTPS 주소로 접속합니다. 기존 앱 인증서는 유지하고 모니터링 인증서만 별도로 추가합니다.

Prometheus에 별도 인증이 구성되어 있지 않으면 도메인을 아는 외부 사용자가 UI·API에 접근할 수 있습니다. 이 변경은 인증을 추가하지 않습니다. 인증을 적용할 경우 LB의 HTTP `/-/ready` 헬스체크가 통과하도록 VM의 프록시 등에서 구성합니다.

아래 명령으로 실제 백엔드 상태를 확인합니다. `PROJECT_ID`는 해당 환경의 프로젝트 ID로 치환합니다.

```bash
gcloud compute backend-services get-health mulo-v2-staging-grafana-service --global --project=PROJECT_ID
gcloud compute backend-services get-health mulo-v2-staging-prometheus-service --global --project=PROJECT_ID
terraform output monitoring_urls
```

## 주요 출력값

| 출력 | 내용 |
| --- | --- |
| `load_balancer_ip`, `site_url` | 외부 접속 주소 |
| `mig_names`, `mig_instance_template_urls` | 앱 MIG와 현재 연결 템플릿 |
| `instance_template_names` | Terraform이 만든 기반 템플릿 |
| `ai_base_url`, `backend_internal_url` | 앱 env에 넣을 고정 내부 주소 |
| `app_env_secret_names` | 서비스별 env 시크릿 이름 |
| `mysql_private_ips`, `postgres_private_ip` | DB 사설 주소 |
| `redis_private_ip`, `redis_port` | Redis 연결 주소·포트 |
| `monitoring_vm_name`, `monitoring_vm_private_ip` | 모니터링 VM 이름·주소 |
| `monitoring_instance_group_name` | 모니터링 비관리형 인스턴스 그룹 이름 |
| `monitoring_urls`, `monitoring_dns_records` | 모니터링 HTTPS 주소와 수동 등록할 DNS 레코드 |
| `image_bucket_name`, `ai_tasks_queue_id` | 이미지 버킷과 AI 작업 큐 |
