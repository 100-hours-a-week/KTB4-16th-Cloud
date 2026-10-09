# 환경 구성과 실행 방법

## 각 폴더의 역할

| 위치 | 역할 |
| --- | --- |
| `environments/dev` | 개발 환경의 Terraform 실행 위치. 입력값과 출력값을 정의하고 `modules/dev_modules`를 호출합니다. |
| `environments/staging` | 스테이징 환경의 실행 위치. `modules/staging_modules`를 호출합니다. |
| `environments/prod` | 운영 환경의 실행 위치. `modules/prod_modules`를 호출합니다. |
| `modules/*` | VM, 네트워크, DB 등의 GCP 리소스를 실제로 선언하는 하위 모듈입니다. 여기서는 직접 Terraform 명령을 실행하지 않습니다. |

각 환경 폴더의 `versions.tf`는 Terraform과 Google 공급자 버전, GCP 프로젝트·리전·존을 설정합니다. `variables.tf`는 입력 변수의 **이름·타입·기본값·검증 조건**을 정의하고, `terraform.tfvars`는 해당 환경의 **실제 값**을 넣습니다. 기본값이 있는 변수는 `terraform.tfvars`에 다시 적지 않아도 됩니다. `terraform.tfvars.example`은 복사해서 수정하는 예시일 뿐 자동으로 읽히지 않습니다.

값은 `terraform.tfvars` → `environments/<환경>/variables.tf`의 `var.*` → `main.tf`의 `module "mulo"` 인수 → 해당 `modules/*`의 리소스 순서로 전달됩니다. `outputs.tf`는 생성된 주소와 이름 중 확인할 값을 노출합니다. 환경별 Terraform 상태는 각 환경 폴더에서 따로 관리합니다. 현재 원격 상태 저장소 설정은 없습니다.

## 환경별 구성

| 항목 | 개발 | 스테이징 | 운영 |
| --- | --- | --- | --- |
| VM | Ubuntu 22.04 LTS `e2-small` 1대, 30GB 디스크 | Ubuntu 22.04 LTS `e2-medium` 5대, 각 30GB | 스테이징과 같은 VM 구성 |
| 서비스 배치 | VM 1대에 frontend·AI·backend·chat 함께 배포 | frontend 1대, AI 2대, backend 1대, chat 1대 | 스테이징과 같음 |
| 접속 | VM 고정 공인 IP; Nginx·Certbot으로 HTTPS 구성 | 글로벌 HTTPS 로드 밸런서와 Google 관리 인증서 | 스테이징과 같음 |
| 네트워크 | 프로젝트의 기존 `default` VPC·서브넷 | 전용 VPC·서브넷, Cloud NAT, IAP SSH 방화벽 | 별도 전용 VPC·서브넷, Cloud NAT, IAP SSH 방화벽 |
| Cloud SQL | 공개 IP MySQL 인스턴스 1대(DB `mulo`, `mulo_chat`)와 PostgreSQL 인스턴스 1대(DB `mulo_ai`) | 사설 IP MySQL 인스턴스 2대(`be`, `chat`)와 PostgreSQL 인스턴스 1대(`ai`) | 스테이징과 별도인 같은 구성 |
| 이미지 | 비공개 GCS 버킷 | 별도 비공개 GCS 버킷 | 별도 비공개 GCS 버킷 |
| Cloud Tasks | 없음 | AI 작업 큐와 OIDC용 서비스 계정 | 별도 AI 작업 큐와 서비스 계정 |
| DB 백업·PITR | 자동 백업·MySQL binlog·PostgreSQL PITR 끔 | 개발과 같음 | 자동 백업·PITR 켬 |
| VM·DB 전원 | `runtime_enabled`로 함께 제어 | `runtime_enabled`로 함께 제어 | 상시 실행 |

읽기 복제본은 어떤 환경에도 없습니다. 스테이징과 운영의 기본 접두사는 각각 `mulo-v2-staging`, `mulo-v2`이고 기본 서브넷 범위는 각각 `10.21.0.0/24`, `10.20.0.0/24`입니다. 두 환경을 같은 GCP 프로젝트에 배포해도 VPC, VM, Cloud SQL 인스턴스와 데이터, 버킷, 로드 밸런서, 작업 큐는 별도로 생성됩니다. 프로젝트 전체의 API 활성화, 할당량, 결제는 공유됩니다. 같은 프로젝트에서 기존 리소스와 이름 또는 IP 범위가 겹치지 않는지 계획에서 확인하세요.

스테이징·운영의 `be` MySQL 인스턴스에는 `mulo`, `chat` MySQL 인스턴스에는 `mulo_chat`, `ai` PostgreSQL 인스턴스에는 `mulo_ai` 데이터베이스가 생성됩니다.

## 적용 전 입력값

1. Terraform 1.6 이상과 GCP 프로젝트를 준비하고 `gcloud auth application-default login`으로 인증합니다. 프로젝트에는 결제 계정이 연결되어 있어야 합니다.
2. 환경 폴더에서 `terraform.tfvars.example`을 `terraform.tfvars`로 복사합니다. `project_id`, `domain`, `image_bucket_name`을 실제 환경에 맞게 확인합니다. 세 환경의 예시 프로젝트 ID는 같지만 반드시 같을 필요는 없습니다.
3. **GCS 버킷 이름은 전역에서 유일하고 환경별로 달라야 합니다.** 현재 개발·스테이징 예시 둘 다 `mulo-develop-1`이므로 하나는 바꿔야 합니다. 스테이징 예시의 `staging.example.com`도 실제 사용할 도메인으로 바꿔야 합니다. 운영 예시의 프로젝트·도메인·버킷도 실제 운영 값인지 확인합니다.
4. 스테이징·운영의 `service_ports`와 `health_paths` 기본값이 앱의 실제 수신 포트와 HTTP 200 응답 경로에 맞는지 확인합니다. 필요한 VM 시작 스크립트는 `startup_scripts`에 넣습니다. 기본값 `{}`이면 VM 생성 후 앱은 자동으로 배포되지 않습니다.

```bash
# 저장소 루트에서, 원하는 환경 하나를 선택합니다.
cd environments/dev       # 또는 environments/staging, environments/prod
cp terraform.tfvars.example terraform.tfvars
# terraform.tfvars 수정
terraform init
terraform fmt -check
terraform validate
terraform plan -out=tfplan
# 계획을 검토한 뒤 실제 배포 시: terraform apply tfplan
```

`terraform.tfvars` 대신 다른 파일을 쓰려면 `terraform plan -var-file=dev.tfvars`처럼 지정합니다. 저장된 계획을 적용할 때는 그 계획 파일을 그대로 사용합니다. 상태 파일은 환경마다 별도로 유지하고 Git에 올리지 않습니다. 현재 원격 백엔드가 없으므로 여러 사람이 함께 적용할 계획이라면 환경별 원격 상태와 잠금을 먼저 구성해야 합니다.

## 개발·스테이징 켜기와 끄기

두 환경의 `terraform.tfvars`에 있는 `runtime_enabled`를 바꾸고 **그 환경 폴더에서** 계획을 확인한 뒤 적용합니다. 최초 생성은 반드시 `true`로 진행합니다. Terraform은 DB 안의 데이터베이스를 생성해야 하므로 처음부터 `false`로 만들 수 없습니다.

```hcl
# 사용 중
runtime_enabled = true

# 사용하지 않을 때 위 값을 아래처럼 변경
runtime_enabled = false
```

```bash
terraform plan -out=tfplan
terraform apply tfplan
terraform output runtime_enabled
```

`false`이면 개발 VM 1대 또는 스테이징 VM 5대가 `TERMINATED`로, 해당 환경의 Cloud SQL 인스턴스가 `NEVER` 활성화 정책으로 바뀝니다. `true`로 바꿔 같은 절차를 실행하면 다시 켜집니다. **VM·DB를 삭제하지 않으므로 데이터와 디스크는 남지만 서비스 접속은 중단됩니다.** 스테이징의 로드 밸런서, Cloud NAT, 버킷과 네트워크도 그대로 남습니다. `runtime_enabled` 출력은 마지막 적용 때의 목표값이며 실시간 전원 상태 조회값은 아닙니다. 다른 `terraform apply`를 실행할 때도 같은 `terraform.tfvars`를 사용하세요.

중지 상태에서도 VM 부팅 디스크와 고정 IP, Cloud SQL 저장 공간, GCS 객체, 스테이징 로드 밸런서 전달 규칙과 NAT IP 등의 비용은 계속 발생할 수 있습니다. 개발·스테이징은 자동 백업·PITR을 끄고 DB 디스크 자동 확장도 껐습니다. DB의 초기 저장 공간은 20GB이며, 용량이 부족해지면 쓰기 실패나 인스턴스 중지가 생길 수 있으므로 확인하세요. 코드에는 별도 VM 스냅샷도 없습니다. 이미 만들어진 수동 백업은 설정 변경만으로 삭제되지 않습니다. 데이터 손실 시 백업이나 시점 복구를 사용할 수 없으므로 시연·테스트 데이터만 넣는 구성을 전제로 합니다.

`sql_deletion_protection` 기본값은 그대로 `true`입니다. 중지는 리소스 삭제가 아니므로 비용을 완전히 없애려면 별도 삭제 절차가 필요합니다.

## 배포 후 연결

### 개발

`terraform output dns_a_record`의 `address`를 개발 도메인의 DNS A 레코드에 넣습니다. `site_url`은 `https://<개발 도메인>` 문자열을 출력하지만, 이것만으로 HTTPS가 열리는 것은 아닙니다. 개발 VM에 Nginx와 Certbot을 배포·설정하고 인증서를 발급해야 합니다. Terraform은 개발 DNS 레코드, Nginx 설정, 인증서를 만들지 않습니다. 자세한 단계는 [개발 README](dev/README.md)를 참고하세요.

개발 Cloud SQL은 공개 IP를 가지지만 허용 네트워크는 개발 VM의 고정 공인 IP `/32`이고 TLS 연결을 요구합니다. 프로젝트에 `default` VPC와 해당 리전의 `default` 서브넷이 있어야 합니다.

### 스테이징·운영

각 폴더의 `terraform output load_balancer_ip`를 해당 환경 도메인의 DNS A 레코드에 넣습니다. 도메인이 로드 밸런서 IP를 가리켜야 Google 관리 인증서 발급이 진행됩니다. VM에는 공인 IP가 없으며 VM에서 인터넷으로 나가는 연결은 Cloud NAT를 사용합니다. 로드 밸런서 상태 검사가 성공하려면 각 VM에서 해당 앱이 설정된 포트와 경로에 HTTP 200으로 응답해야 합니다.

| 요청 경로 | 전달 대상 |
| --- | --- |
| `/api`, `/api/*`, `/image`, `/image/*` | backend VM 그룹 |
| `/ai/search`, `/ai/search/*`, `/internal/tasks`, `/internal/tasks/*` | AI VM 그룹(2대) |
| `/ws`, `/ws/*` | chat VM 그룹 |
| 나머지 | frontend VM 그룹 |

`/image/*` 요청은 버킷으로 바로 가지 않습니다. backend 앱이 로그인과 객체별 권한을 확인한 뒤 비공개 버킷에 읽기·쓰기를 수행해야 합니다. backend 앱은 Cloud Tasks 큐에 HTTP 작업을 등록하고, Cloud Tasks가 `https://<환경 도메인>/internal/tasks/search`로 요청을 전달합니다. 앱이 작업을 생성할 때 OIDC 토큰 설정을 포함해야 하며 AI 앱은 그 토큰을 검증해야 합니다. `terraform output ai_task_target_url`로 목적지를 확인할 수 있습니다.

스테이징·운영은 각 환경의 `mysql_connection_names`, `postgres_connection_name`, `mysql_private_ips`, `postgres_private_ip` 출력을 확인해 앱이 **자기 환경의 DB**에 연결되도록 설정합니다. Cloud SQL 사용자·비밀번호와 PostgreSQL `mulo_ai`의 `pgvector` 확장은 별도로 준비합니다. 확장 SQL은 [enable-pgvector.sql](../enable-pgvector.sql)에 있습니다.

## Terraform이 설치하는 범위

Terraform은 인프라를 만들지만 애플리케이션 프로세스, DB 사용자, DNS 레코드를 배포하지 않습니다. 개발 VM의 [bootstrap.sh](dev/bootstrap.sh)는 Docker·Compose, Google Cloud CLI, Ops Agent, 스왑과 디렉터리만 준비합니다. 스테이징·운영의 `startup_scripts` 기본값은 비어 있습니다. 앱 배포와 DB 연결 설정은 각 환경에서 따로 수행해야 합니다.

이 저장소는 코드 작성 및 로컬 검증 단계이며 실제 GCP 리소스는 아직 만들지 않았습니다.
