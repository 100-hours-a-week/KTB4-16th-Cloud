# MULO v2 Terraform

개발, 스테이징, 운영 인프라를 GCP에 만드는 Terraform 코드입니다. **Terraform 명령은 저장소 최상위가 아니라 `environments/dev`, `environments/staging`, `environments/prod` 중 배포할 폴더에서 실행합니다.** 실제 GCP 배포는 아직 하지 않았습니다.

| 환경 | 구성 | 안내 |
| --- | --- | --- |
| 개발 | Ubuntu 22.04 VM 1대에 서비스 4개, 공개 IP Cloud SQL, VM의 Nginx·Certbot | [개발 README](environments/dev/README.md) |
| 스테이징 | Ubuntu 22.04 VM 5대, 전용 VPC, 사설 IP Cloud SQL, HTTPS 로드 밸런서, Cloud Tasks | [스테이징 README](environments/staging/README.md) |
| 운영 | 스테이징과 같은 구성의 별도 리소스 | [운영 README](environments/prod/README.md) |

## 폴더 구조

```text
environments/
  dev/                 개발 환경에서 Terraform을 실행하는 폴더
  staging/             스테이징 환경에서 Terraform을 실행하는 폴더
  prod/                운영 환경에서 Terraform을 실행하는 폴더
  README.md            공통 구성과 실행 방법
modules/
  dev_modules/         개발 리소스 정의
  staging_modules/     스테이징 리소스 정의
  prod_modules/        운영 리소스 정의
enable-pgvector.sql    mulo_ai DB에서 실행할 pgvector 활성화 SQL
```

`environments/<환경>/main.tf`의 `module "mulo"`가 해당 환경의 `modules/<환경>_modules/`를 호출합니다. `environments`는 입력값, 공급자 설정, 출력값, Terraform 상태를 관리하는 **루트 모듈**이고, `modules`는 실제 GCP 리소스를 정의하는 **하위 모듈**입니다. 모듈 폴더에서 `terraform apply`를 실행하지 않습니다.

## 시작하기

Terraform 1.6 이상과 GCP 인증을 준비한 뒤, 배포할 환경의 README를 먼저 읽으세요. 예를 들어 개발 환경은 다음과 같습니다.

```bash
cd environments/dev
cp terraform.tfvars.example terraform.tfvars
# terraform.tfvars의 프로젝트 ID, 도메인, 버킷 이름을 확인하고 수정
gcloud auth application-default login
terraform init
terraform fmt -check
terraform validate
terraform plan -out=tfplan
```

`terraform.tfvars.example`은 자동으로 읽히지 않습니다. 실제 값은 복사한 `terraform.tfvars`에 넣거나 `terraform plan -var-file=파일명.tfvars`로 전달합니다. `terraform.tfvars`와 상태 파일은 `.gitignore`에 포함되어 있습니다. 계획을 검토한 뒤 배포할 때만 `terraform apply tfplan`을 실행합니다.


개발·스테이징은 Cloud SQL 자동 백업·PITR와 디스크 자동 확장을 끄고, `runtime_enabled` 값으로 VM·DB를 켜고 끌 수 있습니다. 최초 생성은 `true`로 진행합니다. 중지해도 디스크·IP 등 유지 비용은 남습니다. 운영 환경의 백업 설정과 상시 실행 방식은 유지합니다.

## 아직 수정이 필요한 사항

1. **Cloud Tasks 목적지 URL:** [스테이징](modules/staging_modules/outputs.tf)과 [운영](modules/prod_modules/outputs.tf)의 `ai_task_target_url`은 현재 `https://<도메인>/internal/tasks/*`를 출력합니다. `*`는 로드 밸런서 경로 규칙에서 쓰는 패턴이며 실제 HTTP 작업의 목적지에서는 문자 그대로 전달됩니다. AI 앱의 실제 처리 경로가 `/internal/tasks/search`라면 두 출력값을 그 경로로 바꾸세요. 다른 작업 경로도 사용한다면 앱에서 각 작업의 전체 URL을 만들어야 합니다. [Cloud Tasks URL 형식](https://docs.cloud.google.com/tasks/docs/create-tasks)을 참고하세요.
2. **경로 규칙과 문서:** 두 환경의 [로드 밸런서 규칙](modules/staging_modules/load_balancer.tf)은 `/ai/*`와 `/internal/tasks/*`만 AI로 보냅니다. `/ai/search`는 포함되지만 `/ai`와 `/internal/tasks` 자체는 기본 frontend로 갑니다. [환경 안내](environments/README.md)의 경로 표는 `/internal/tasks`도 AI로 간다고 적혀 있으므로, 실제 앱 경로에 맞춰 규칙이나 설명을 맞춰야 합니다. [URL 맵 경로 일치 방식](https://docs.cloud.google.com/load-balancing/docs/url-map-concepts)을 참고하세요.


