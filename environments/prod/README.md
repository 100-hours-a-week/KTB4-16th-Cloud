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
| 모니터링 | 독립 VM | 1대 | `e2-medium`, 50GB |

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
| 이미지 버킷 | 기존 버킷 조회 | backend에 객체 관리 권한 부여 |

기존 DB 이름은 `existing_backend_mysql_instance_name`, `existing_ai_postgres_instance_name`으로 지정합니다. [imports.tf](imports.tf)가 두 인스턴스를 Terraform 관리 대상으로 연결합니다. 기존 버킷 이름은 `image_bucket_name`으로 지정합니다.

기존 DB에는 운영 VPC의 사설 IP 연결을 추가하면서 공인 IP와 TLS 필수 설정도 유지합니다. 새 chat DB는 사설 IP만 사용합니다. 기존 DB 두 대의 기본 사양은 `db-g1-small`, 디스크 크기는 기존 값을 유지하며, 신규 chat DB는 기본 20GB입니다. 백업·MySQL binlog·PostgreSQL PITR과 디스크 자동 확장은 활성화되어 있습니다.

기존 DB에는 삭제 보호가 적용되고 Terraform의 삭제·교체도 차단합니다. 기존 버킷 설정과 객체는 직접 관리 대상으로 등록하지 않으며, backend 계정의 버킷 권한만 관리합니다.

## 앱과 공용 서비스

[bootstrap.sh](bootstrap.sh)는 최초에 Docker·Google Cloud CLI·Ops Agent와 스왑을 준비하고, 매 부팅마다 이미지와 Secret Manager의 env로 앱을 실행합니다. Node Exporter도 자동으로 실행합니다. Redis·모니터링은 [base-bootstrap.sh](base-bootstrap.sh)의 기존 설치 방식을 유지하며 서비스는 직접 관리합니다.

최초 적용과 CD 연결은 [앱 부팅 전환 안내](../BOOTSTRAP.md), 교체·헬스체크·내부 서비스 주소는 [공통 MIG 설명](../README.md#앱-mig의-동작)을 참고하세요.

`vm_image`는 앱·Redis·모니터링에 공통으로 적용되는 GCE 부팅 이미지입니다. `service_container_images`에는 태그 없는 Docker 이미지 경로, `service_image_tags`에는 최초 태그를 지정합니다. 이후 배포 태그와 현재 MIG 템플릿은 CD가 관리합니다.

Cloud Tasks 큐는 기본 `mulo-v2-ai-task`입니다. Redis·모니터링의 내부 통신과 앱 권한 범위는 [공통 구성](../README.md)에 정리되어 있습니다.

운영은 staging과 달리 24시간 실행하므로 별도 전원 관리 스크립트가 필요하지 않습니다.

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
| `image_bucket_name`, `ai_tasks_queue_id` | 이미지 버킷과 AI 작업 큐 |
