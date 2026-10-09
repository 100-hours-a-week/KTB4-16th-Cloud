# 개발 환경

이 폴더가 개발 환경의 Terraform 실행 위치입니다. [`main.tf`](main.tf)는 [`modules/dev_modules`](../../modules/dev_modules)을 호출합니다. Ubuntu 22.04 LTS `e2-small` VM 1대(30GB 디스크)에 frontend·AI·backend·chat을 함께 배포하는 구성입니다. Terraform은 VM과 고정 공인 IP, Cloud SQL, 비공개 이미지 버킷을 만듭니다. Cloud Tasks와 로드 밸런서는 없습니다.

## 설정과 실행

```bash
# 저장소 루트에서 시작
cd environments/dev
cp terraform.tfvars.example terraform.tfvars
# project_id, domain, image_bucket_name을 실제 개발 값으로 확인·수정
gcloud auth application-default login
terraform init
terraform fmt -check
terraform validate
terraform plan -out=tfplan
# 계획 검토 후 실제 배포 시: terraform apply tfplan
```


## HTTPS와 앱 배포

적용 후 `terraform output dns_a_record`의 `address`를 개발 도메인의 DNS A 레코드로 등록합니다. 이 주소는 VM의 고정 공인 IP입니다. [`bootstrap.sh`](bootstrap.sh)는 VM 시작 시 Docker·Compose, Google Cloud CLI, Ops Agent, 기본 유틸리티, 2GB 스왑과 `/home/ubuntu/app/data/{nginx,certbot}` 디렉터리를 준비합니다. VM 방화벽은 외부 TCP 80·443번을 허용합니다.

Nginx·Certbot 설정과 인증서 발급, 서비스 컨테이너 시작은 직접 배포해야 합니다. `terraform output site_url`은 `https://<domain>`을 표시할 뿐 HTTPS가 이미 동작한다는 뜻은 아닙니다. Nginx에서 `/api`·`/image`를 backend, `/ai/search`를 AI, `/ws`를 chat, 나머지를 frontend로 보내도록 구성할 수 있습니다. 네 서비스를 한 `e2-small`에 올리는 만큼 실제 메모리 사용량을 확인하세요.

## 데이터베이스와 이미지

MySQL 인스턴스 1대에 `mulo`·`mulo_chat` DB를, PostgreSQL 인스턴스 1대에 `mulo_ai` DB를 만듭니다. 두 인스턴스는 공개 IP를 가지지만 개발 VM의 고정 IP `/32`만 접속하도록 허용하고 TLS를 요구합니다. `terraform output mysql_public_ip`, `terraform output postgres_public_ip`로 주소를 확인합니다. DB 사용자·비밀번호는 Terraform 코드에서 만들지 않습니다. PostgreSQL의 pgvector는 `mulo_ai`에 접속해 [SQL 파일](../../enable-pgvector.sql)을 실행해야 합니다.

이미지 버킷은 공개하지 않습니다. 개발 VM 서비스 계정에 해당 버킷의 객체 관리 권한이 있으므로, 앱이 인증과 권한 확인 후 이미지 업로드·조회 요청을 처리해야 합니다. 전체 환경 비교는 [공통 안내](../README.md)를 참고하세요.

## 사용하지 않을 때 중지하기

개발 DB의 자동 백업, MySQL binlog, PostgreSQL PITR, 디스크 자동 확장은 꺼져 있습니다. `terraform.tfvars`의 `runtime_enabled = true`로 **최초 생성**한 뒤, 사용하지 않을 때 `false`로 바꾸고 아래 명령을 실행하세요. 개발 VM 1대와 Cloud SQL 2대가 중지되며 데이터는 남습니다. 다시 사용할 때 `true`로 바꿔 같은 명령을 실행합니다.

```bash
terraform plan -out=tfplan
terraform apply tfplan
terraform output runtime_enabled
```

중지 중에는 사이트와 DB에 접속할 수 없습니다. VM 부팅 디스크·고정 공인 IP, Cloud SQL 저장 공간과 버킷 객체 비용은 남습니다. DB의 초기 저장 공간은 20GB이며 자동 확장을 껐으므로 용량을 확인하세요. 자동 백업이 없으니 시연·테스트 데이터만 넣으세요. 자세한 비용과 제한은 [공통 안내](../README.md#개발스테이징-켜기와-끄기)를 참고하세요.
