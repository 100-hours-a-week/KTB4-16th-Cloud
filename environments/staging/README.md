# 스테이징 환경

이 폴더가 스테이징 환경의 Terraform 실행 위치입니다. [`main.tf`](main.tf)는 [`modules/staging_modules`](../../modules/staging_modules)을 호출합니다. Ubuntu 22.04 LTS `e2-medium` VM 5대(frontend·backend·chat 각 1대, AI 2대), VM당 30GB 디스크, 전용 VPC, 사설 IP Cloud SQL, 비공개 이미지 버킷, 글로벌 HTTPS 로드 밸런서, Cloud Tasks 큐를 만듭니다. 읽기 복제본은 없습니다.

운영과 규모는 같아도 스테이징 접두사 `mulo-v2-staging`과 서브넷 기본값 `10.21.0.0/24`를 사용해 별도 리소스를 만듭니다. 같은 GCP 프로젝트를 사용할 수 있지만 스테이징 앱은 스테이징 DB에만 연결하도록 설정해야 합니다. 프로젝트 단위 API 활성화·할당량·결제는 공유됩니다. [환경 공통 안내](../README.md)에 라우팅과 DB 구성 설명이 있습니다.

## 설정과 실행

```bash
# 저장소 루트에서 시작
cd environments/staging
# terraform.tfvars가 없다면: cp terraform.tfvars.example terraform.tfvars
# terraform.tfvars의 TODO(도메인·버킷)를 확인·수정
gcloud auth application-default login
terraform init
terraform fmt -check
terraform validate
terraform plan -out=tfplan
# 계획 검토 후 실제 배포 시: terraform apply tfplan
```


## 적용 후

`terraform output load_balancer_ip`를 스테이징 도메인의 DNS A 레코드에 넣어 관리형 HTTPS 인증서가 발급되도록 합니다. 각 서비스 앱을 배포하고 기본 상태 검사 경로(frontend `/`, AI `/health`, backend `/actuator/health`, chat `/health`)에서 HTTP 200을 반환하도록 합니다. **헬스 경로는 아직 확정되지 않았기 때문에 수정될 여지가 있습니다.**

`terraform output mysql_connection_names`와 `terraform output postgres_connection_name`으로 스테이징 DB 연결 대상을 확인합니다. DB 사용자와 PostgreSQL `mulo_ai`의 pgvector 확장은 별도로 준비합니다. 이미지 조회·업로드는 권한을 확인하는 backend 앱을 거치며 버킷은 비공개입니다. Cloud Tasks 목적지는 `terraform output ai_task_target_url`로 확인하고, AI 앱에서 작업 요청의 OIDC 토큰을 검증해야 합니다.

## 사용하지 않을 때 중지하기

스테이징 DB의 자동 백업, MySQL binlog, PostgreSQL PITR, 디스크 자동 확장은 꺼져 있습니다. 로드 밸런서 백엔드 서비스의 요청 로그도 비활성화했습니다. `terraform.tfvars`의 `runtime_enabled = true`로 **최초 생성**한 뒤, 사용하지 않을 때 `false`로 바꾸고 아래 명령을 실행하세요. VM 5대와 Cloud SQL 3대가 중지됩니다. 다시 사용할 때 `true`로 바꿔 같은 명령을 실행합니다.

```bash
terraform plan -out=tfplan
terraform apply tfplan
terraform output runtime_enabled
```

중지 중에는 도메인이 로드 밸런서를 계속 가리키지만 정상적인 앱 응답을 받을 수 없습니다. VM 디스크, DB 저장 공간, 버킷, 로드 밸런서 전달 규칙, NAT IP 등에는 비용이 남습니다. DB의 초기 저장 공간은 각 20GB이며 자동 확장을 껐으므로 용량을 확인하고 시연·테스트 데이터만 넣으세요. 자세한 내용은 [공통 안내](../README.md#개발스테이징-켜기와-끄기)를 참고하세요.

## 수정 사항

스테이징 도메인은 우선 `staging.mulostudio.com`으로 정했습니다. 실제 사용할 도메인이 다르면 `terraform.tfvars`를 수정하세요. 버킷 이름은 `mulo-v2-staging-images-7b071b48-8637-467a-80d`로 정했으며 운영 버킷과 분리됩니다.

모든 스테이징 VM(frontend·AI 2대·backend·chat)에 [`bootstrap.sh`](bootstrap.sh)가 VM 시작 시 적용됩니다. Docker·Compose, Google Cloud CLI, Ops Agent와 2GB 스왑을 준비하며 앱 배포는 포함하지 않습니다. 별도의 서비스별 `startup_scripts` 입력은 제거했습니다.

`terraform validate`와 `terraform plan -input=false`가 성공했습니다. 계획은 신규 리소스 55개, 변경·삭제 0개이며 실제 적용은 하지 않았습니다.
