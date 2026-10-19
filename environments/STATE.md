# 팀 공유 Terraform state

각 환경의 `backend.tf`는 GCS 버킷 `mulo-v2-tfstate-953840519216`을 사용합니다. 이 설정만 추가해도 기존 로컬 state가 자동으로 이전되지는 않습니다. 버킷과 권한을 먼저 준비하고 아래 이전 절차를 환경별로 수행합니다.

| 환경 | prefix | 기본 workspace의 state 객체 |
| --- | --- | --- |
| dev | `dev` | `dev/default.tfstate` |
| staging | `staging` | `staging/default.tfstate` |
| prod | `prod` | `prod/default.tfstate` |

Git에는 IaC 코드, `backend.tf`, `.terraform.lock.hcl`을 공유합니다. state·백업·plan·실제 env와 `terraform.tfvars`는 기존 `.gitignore`에 따라 제외합니다.

## 버킷 준비

1. 프로젝트 `project-7b071b48-8637-467a-80d`에 이름이 `mulo-v2-tfstate-953840519216`인 비공개 GCS 버킷을 준비합니다. 버킷은 백엔드를 초기화하기 전에 존재해야 합니다. 다른 이름을 사용하면 세 환경의 `backend.tf`도 같은 이름으로 수정합니다.
2. 버킷의 객체 버전 관리를 활성화합니다. 이전 state 버전은 잘못된 변경이나 삭제에서 복구할 때 사용합니다.
3. Terraform을 실행할 팀 계정 또는 그룹에 해당 버킷 범위의 `roles/storage.objectAdmin` 권한을 부여합니다. 인프라를 관리하는 GCP 권한은 별도로 필요합니다.

GCS 백엔드는 state 잠금을 지원합니다. 인증은 로컬 ADC를 사용합니다. [GCS 백엔드 공식 문서](https://developer.hashicorp.com/terraform/language/backend/gcs)

## 기존 로컬 state 이전

최신 로컬 state가 있는 컴퓨터에서 환경별로 한 번만 이전합니다. 이전하는 동안 해당 환경의 다른 Terraform 실행은 중단합니다. 기존 `terraform.tfstate`와 백업을 보관하고, 이전 대상 GCS 경로에 다른 state가 이미 있으면 덮어쓰기 전에 어느 쪽이 최신인지 확인합니다.

저장소 루트에서 prod를 이전하는 예시입니다. staging과 dev는 폴더 이름을 바꿔 각각 실행합니다.

```bash
gcloud auth application-default login
cd environments/prod
terraform init -migrate-state
terraform state list
```

이미 올바른 ADC 계정으로 인증되어 있다면 로그인 단계는 생략합니다. state 복사 확인 질문에 승인한 뒤, 기존 리소스가 목록에 유지되는지와 GCS의 `prod/default.tfstate`를 확인합니다. state 이전은 저장 위치를 바꾸며 인프라에 `apply`를 수행하지 않습니다.

이전 전에 저장한 plan은 재사용하지 않고 새로 생성합니다. `terraform plan`에서 기존 리소스를 대량으로 새로 생성하려는 계획이 나타나면 백엔드의 버킷·prefix·workspace와 이전된 state를 확인합니다. staging의 중지된 Cloud SQL을 조회하는 계획은 [staging 시작 절차](staging/README.md#스테이징-전체-중지와-시작)에 따라 DB가 실행 중일 때 확인합니다.

`-migrate-state`는 기존 state를 복사합니다. 최초 이전 담당자는 이 옵션을 사용합니다. [Terraform init 공식 문서](https://developer.hashicorp.com/terraform/cli/commands/init#backend-initialization)

## 팀원 연결

최초 이전이 완료된 뒤 팀원은 같은 코드와 백엔드 설정을 받고 해당 환경 폴더에서 실행합니다.

```bash
gcloud auth application-default login
terraform init -reconfigure
terraform state list
```

`-reconfigure`는 팀원의 이전 로컬 state를 업로드하지 않고 설정된 GCS 백엔드에 연결합니다. 이후 `plan`과 `apply`는 해당 환경의 원격 state를 사용합니다. 팀원의 오래된 로컬 state를 `-migrate-state`로 다시 복사하지 않습니다.
