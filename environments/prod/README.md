# 운영 환경

앱은 스테이징과 같은 MIG 배치를 사용하고, 기존 운영 backend·AI DB와 이미지 버킷을 재사용합니다. 신규 chat DB와 운영 전용 VPC·로드 밸런서·Cloud Tasks 큐를 구성합니다.

앱 자동 부팅을 처음 적용할 때는 staging의 정상 부팅을 확인한 뒤 [최초 전환 순서](../BOOTSTRAP.md#2-최초-적용)를 진행합니다. prod의 시크릿에 실제 env를 등록한 다음 새 템플릿을 연결합니다.

[공통 요청 흐름](../README.md#스테이징운영의-요청-흐름) · [루트 모듈](main.tf) · [리소스 정의](../../modules/prod_modules)

## VM 구성

| 용도 | 관리 방식 | 수량 | 기본 사양 |
| --- | --- | --- | --- |
| frontend | MIG | 1대 | `e2-medium`, 30GB |
| backend | MIG | 1대 | `e2-medium`, 30GB |
| AI | MIG | 2대 | 각 `e2-medium`, 30GB |
| chat | MIG | 1대 | `e2-medium`, 30GB |
| Redis | 독립 VM | 1대 | `e2-medium`, 30GB |
| 모니터링 | 비관리형 인스턴스 그룹의 기존 VM | 1대 | `e2-medium`, 50GB |

총 VM 7대이며 기본 OS는 Ubuntu 22.04입니다. 앱 VM은 내부 IP를 자동 할당받고, Redis와 모니터링은 고정 내부 IP를 사용합니다. Redis와 모니터링은 앱 롤링 배포 대상에서 제외됩니다.

## 요청이 들어오는 경로

사용자 요청은 **HTTPS LB → 경로에 해당하는 앱 MIG → 서비스 VM** 순서로 전달됩니다. 라우팅·포트·헬스체크는 [공통 경로 표](../README.md#스테이징운영의-요청-흐름)를 사용합니다.

운영 전용 서브넷은 기본 `10.20.0.0/24`, 리소스 접두사는 `mulo-v2`입니다. VM의 외부 통신은 Cloud NAT, SSH 접속은 IAP를 사용합니다. LB의 연결 드레이닝은 **300초**, 요청 로그는 활성화되어 있습니다.

## 기존 리소스와 신규 리소스

| 대상 | 처리 방식 | 데이터 구성 |
| --- | --- | --- |
| backend MySQL | 기존 인스턴스를 Terraform에서 관리 | MySQL 8.4, 기존 DB 사용 |
| AI PostgreSQL | 기존 인스턴스를 Terraform에서 관리 | PostgreSQL 18, 기존 DB 사용 |
| chat MySQL | `mulo-v2-mysql-chat` 생성 | MySQL 8.4, `mulo_chat` DB 생성 |
| 이미지 버킷 | 기존 버킷 조회 | backend에 객체 관리, AI에 객체 읽기 권한 부여 |

기존 DB 이름은 `existing_backend_mysql_instance_name`, `existing_ai_postgres_instance_name`으로 지정합니다. [imports.tf](imports.tf)가 두 인스턴스를 Terraform 관리 대상으로 연결합니다. 기존 버킷 이름은 `image_bucket_name`으로 지정합니다.

기존 DB에는 운영 VPC의 사설 IP 연결을 추가하면서 공인 IP와 TLS 필수 설정도 유지합니다. 새 chat DB는 사설 IP만 사용합니다. 기존 DB 두 대의 기본 사양은 `db-g1-small`, 디스크 크기는 기존 값을 유지하며, 신규 chat DB는 기본 20GB입니다. 백업·MySQL binlog·PostgreSQL PITR과 디스크 자동 확장은 활성화되어 있습니다.

기존 DB에는 삭제 보호가 적용되고 Terraform의 삭제·교체도 차단합니다. 기존 버킷 설정과 객체는 직접 관리 대상으로 등록하지 않으며, backend·AI 계정의 버킷 권한만 관리합니다.

## 운영 수동 설정의 Terraform 관리

운영 backend와 AI에는 각 서비스 계정 자기 자신에 대한 `roles/iam.serviceAccountTokenCreator`를 부여합니다. AI에는 기존 사진 버킷의 `roles/storage.objectViewer`도 부여합니다. 외부 LB 요청 제한 시간은 backend 120초, AI 300초, chat 3600초, frontend 30초입니다.

[iam.tf](iam.tf)는 `github-actions-ci`의 프로젝트 단위 `roles/containeranalysis.occurrences.viewer`와 커스텀 역할 `ciHealthCheckUser`를 관리합니다. 커스텀 역할에는 `compute.healthChecks.use`, `compute.healthChecks.useReadOnly`만 포함합니다. CI 권한은 프로젝트 공용이지만 리소스는 prod 상태에서만 관리합니다.

`mulo-v2-be-reader-password`는 시크릿 껍데기와 자동 복제 설정만 관리합니다. 비밀번호 값·버전과 이 시크릿의 접근 권한은 추가하지 않습니다.

수동으로 만든 위 IAM·커스텀 역할·시크릿의 [import 블록](imports.tf)을 유지해 기존 리소스를 재사용합니다. `terraform -chdir=environments/prod plan`으로 import와 변경 사항을 검토한 뒤 적용합니다. staging/dev의 자기 서명 권한은 각 환경의 모듈과 상태에서 별도로 관리합니다.

## 앱과 공용 서비스

[bootstrap.sh](bootstrap.sh)는 최초에 Docker·Google Cloud CLI·Ops Agent와 스왑을 준비하고, 매 부팅마다 이미지와 Secret Manager의 env로 앱을 실행합니다. Node Exporter도 자동으로 실행합니다. Redis·모니터링은 [base-bootstrap.sh](base-bootstrap.sh)의 기존 설치 방식을 유지하며 서비스는 직접 관리합니다.

최초 적용과 CD 연결은 [앱 부팅 전환 안내](../BOOTSTRAP.md), 교체·헬스체크·내부 서비스 주소는 [공통 MIG 설명](../README.md#앱-mig의-동작)을 참고하세요.

`vm_image`는 앱·Redis·모니터링에 공통으로 적용되는 GCE 부팅 이미지입니다. `service_container_images`에는 태그 없는 Docker 이미지 경로, `service_image_tags`에는 최초 태그를 지정합니다. 이후 배포 태그와 현재 MIG 템플릿은 CD가 관리합니다.

Cloud Tasks 큐는 기본 `mulo-v2-ai-task`입니다. Redis·모니터링의 내부 통신과 앱 권한 범위는 [공통 구성](../README.md)에 정리되어 있습니다.

운영은 staging과 달리 24시간 실행하므로 별도 전원 관리 스크립트가 필요하지 않습니다.

### Docker 로그 수집

AI·backend·chat의 부팅 스크립트는 Grafana Alloy를 설치하고 Docker stdout·stderr 로그를 Loki로 전송합니다. 전송 주소는 예약된 모니터링 내부 IP의 `3100/loki/api/v1/push`이며, 템플릿의 `alloy-service`·`alloy-environment`·`alloy-loki-url` 메타데이터로 설정합니다. 로그에는 `job="docker-logs"`, `environment="prod"`, 서비스·VM 호스트명·컨테이너 이름을 라벨로 붙입니다.

Alloy 설정은 `/etc/alloy/config.alloy`에 저장하며 `alloy validate`를 통과한 파일만 반영합니다. `alloy` 사용자에게 Docker 그룹 권한을 부여하고 Docker 이후 Alloy를 자동 시작합니다. 기존 설치 완료 표시가 있거나 Chat 앱 이미지가 없어도 Alloy 설치 여부는 별도로 확인합니다. Alloy 설치·설정·재시작 또는 Loki 준비 확인이 실패해도 경고를 기록하고 앱 시작은 계속합니다. 실패 원인은 `/var/log/mulo-bootstrap.log`와 `journalctl -u alloy`에서 확인합니다.

frontend는 같은 부팅 스크립트를 사용하므로 템플릿 교체 대상에 포함되지만 Alloy 설치는 건너뜁니다. 기존 Loki 수신 방화벽을 사용하며 Loki 서버 설치는 포함하지 않습니다.

**기존 운영 VM에는 Terraform 적용만으로 Alloy가 설치되지 않습니다.** MIG는 `ignore_changes = [version]`으로 CD 템플릿을 유지합니다. 실제 전환 전 현재 배포 이미지·태그를 Terraform 입력과 맞추고 [부팅 템플릿 전환 안내](../BOOTSTRAP.md#3-terraform과-cd가-공유하는-값)에 따라 새 계획을 검토하거나, CD가 사용하는 템플릿에 부팅 스크립트와 Alloy 메타데이터를 함께 반영해야 합니다. 이전 이미지 태그를 둔 채 version 무시만 해제하면 앱 버전이 되돌아갈 수 있습니다.

## 모니터링 도메인 접속

기존 모니터링 VM을 `google_compute_instance_group.monitoring` 비관리형 그룹에 등록하고, 기존 외부 HTTPS LB에 Grafana·Prometheus 백엔드를 추가합니다. VM·디스크·고정 내부 IP는 그대로 사용하며 앱 MIG의 롤링 배포나 자동 복구 대상에 포함하지 않습니다.

| 서비스 | 기본 주소 | VM 수신 포트 | 헬스체크 |
| --- | --- | --- | --- |
| Grafana | `https://grafana.mulostudio.com` | 3000 | `/api/health` |
| Prometheus | `https://prometheus.mulostudio.com` | 9090 | `/-/ready` |

주소는 이 환경의 `domain`에 서비스 이름을 붙여 생성합니다. 실제 VM의 공개 포트가 다르면 `terraform.tfvars`의 `monitoring_ports = { grafana = 3000, prometheus = 9090 }`으로 조정합니다. 방화벽은 Google LB·헬스체크 주소에서 이 두 포트로 들어오는 TCP만 허용하고, Loki 3100 포트는 외부 LB에 연결하지 않습니다.

1. VM에서 Grafana·Prometheus를 실행하고 VM 내부 IP 또는 `0.0.0.0`의 해당 포트에 바인딩합니다. Docker Compose 사용 시 VM 포트로 publish해야 합니다. Terraform은 두 서비스를 설치하거나 Compose 설정을 변경하지 않습니다.
2. Grafana의 `GF_SERVER_ROOT_URL`을 `terraform output -json monitoring_urls`의 Grafana 주소에 맞춥니다. Prometheus의 `--web.external-url`도 해당 HTTPS 주소로 맞춥니다. TLS는 LB에서 종료하고 VM에는 HTTP로 전달합니다.
3. `terraform plan -out=monitoring.tfplan`으로 VM·디스크 교체가 없는지 확인하고 검토한 계획을 적용합니다.
4. `terraform output -json monitoring_dns_records`에 나온 두 A 레코드를 외부 DNS에 등록합니다. DNS는 이 저장소에서 관리하지 않습니다. 동일 호스트에 AAAA 레코드가 있으면 이 LB의 주소와 일치하는지도 확인합니다.
5. 서비스별 Google 관리 인증서가 `ACTIVE`이고 백엔드가 `HEALTHY`인 것을 확인한 뒤 위 HTTPS 주소로 접속합니다. 기존 앱 인증서는 유지하고 모니터링 인증서만 별도로 추가합니다.

Prometheus에 별도 인증이 구성되어 있지 않으면 도메인을 아는 외부 사용자가 UI·API에 접근할 수 있습니다. 이 변경은 인증을 추가하지 않습니다. 인증을 적용할 경우 LB의 HTTP `/-/ready` 헬스체크가 통과하도록 VM의 프록시 등에서 구성합니다.

아래 명령으로 실제 백엔드 상태를 확인합니다. `PROJECT_ID`는 해당 환경의 프로젝트 ID로 치환합니다.

```bash
gcloud compute backend-services get-health mulo-v2-grafana-service --global --project=PROJECT_ID
gcloud compute backend-services get-health mulo-v2-prometheus-service --global --project=PROJECT_ID
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
| `mysql_private_ips`, `postgres_private_ip` | 기존 DB와 chat DB의 사설 주소 |
| `redis_private_ip`, `redis_port` | Redis 연결 주소·포트 |
| `monitoring_vm_name`, `monitoring_vm_private_ip` | 모니터링 VM 이름·주소 |
| `monitoring_instance_group_name` | 모니터링 비관리형 인스턴스 그룹 이름 |
| `monitoring_urls`, `monitoring_dns_records` | 모니터링 HTTPS 주소와 수동 등록할 DNS 레코드 |
| `image_bucket_name`, `ai_tasks_queue_id` | 이미지 버킷과 AI 작업 큐 |
