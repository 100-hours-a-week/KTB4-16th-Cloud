# 운영 환경

이 폴더가 운영 환경의 Terraform 실행 위치입니다. [`main.tf`](main.tf)는 운영 전용 [`modules/prod_modules`](../../modules/prod_modules)을 호출합니다. 기본값은 접두사 `mulo-v2`, `asia-northeast3` / `asia-northeast3-a`, 서브넷 `10.20.0.0/24`, Ubuntu 22.04 LTS `e2-medium`, VM당 30GB 디스크입니다. frontend·backend·chat VM 각 1대와 AI VM 2대가 생성됩니다.

운영은 전용 VPC, 기존 운영 DB·이미지 버킷 재사용, 신규 chat MySQL, 글로벌 HTTPS 로드 밸런서, Cloud Tasks 큐를 사용합니다. VM 규모는 스테이징과 같지만 DB와 버킷은 운영의 기존 데이터를 사용합니다. [환경 공통 안내](../README.md)에서 전체 구조와 앱 연결 방식을 확인하세요.



```bash
# 저장소 루트에서 시작
cd environments/prod
# 이미 만들어 둔 terraform.tfvars의 운영 DB 이름·버킷·도메인 확인
gcloud auth application-default login
terraform init
terraform fmt -check
terraform validate
terraform plan -out=tfplan
# 계획 검토 후 실제 배포 시: terraform apply tfplan
```

## 수정 사항

모든 운영 VM(frontend·AI 2대·backend·chat)에 [`bootstrap.sh`](bootstrap.sh)가 VM 시작 시 적용됩니다. Docker·Compose, Google Cloud CLI, Ops Agent와 2GB 스왑을 준비하며 앱 배포는 포함하지 않습니다. 별도의 서비스별 `startup_scripts` 입력은 제거했습니다.

기존 `backend-db-1`의 `mulo`, `ai-db-1`의 `muro_ai`, `muro-bucket-1`을 그대로 사용합니다. [`imports.tf`](imports.tf)는 기존 DB 두 대를 운영 Terraform 상태에 가져오고, 각 DB에 v2 VPC의 사설 IP를 추가합니다. 기존 DB를 새로 생성하지 않으며 공인 IP·기존 허용 IP·백업·TLS 설정은 유지합니다. 두 DB에는 Terraform의 `prevent_destroy`와 Cloud SQL 삭제 보호가 적용됩니다. 버킷은 `data`로 조회해 버킷 자체를 관리하지 않고, 새 backend VM 서비스 계정에 `roles/storage.objectAdmin`만 추가합니다. `mulo-v2-mysql-chat` 인스턴스와 `mulo_chat` DB는 새로 생성합니다. 기존 DB가 다른 Terraform 상태에서 관리 중이면 동일한 인스턴스를 두 상태에 동시에 등록하지 말고 상태 이전을 먼저 계획해야 합니다.

기존 버킷의 현재 설정은 균일한 버킷 수준 액세스와 공개 액세스 방지가 켜져 있고, 버킷 IAM에 `allUsers` 읽기 권한이 없습니다. Terraform은 이 설정을 수정하지 않습니다. 이미지 조회·업로드는 backend 앱이 사용자 권한을 검사한 다음 버킷에 접근하도록 배포해야 합니다.

운영 앱은 `mysql_private_ips.be`(backend MySQL), `postgres_private_ip`(AI PostgreSQL), `mysql_private_ips.chat`(신규 chat MySQL)으로 사설 IP에 직접 연결합니다. DB 사용자·비밀번호와 앱 연결 설정은 별도로 준비해야 합니다. 기존 운영 DB의 TLS 모드는 `ENCRYPTED_ONLY`이므로 앱의 DB 클라이언트에도 TLS를 설정해야 합니다. 기존 VM은 기존 공인 IP 접속을 유지할 수 있지만, **사설 IP를 추가하는 작업 중 두 DB가 재시작되어 기존 운영 서비스에도 일시 중단이 발생합니다.** 실제 적용은 점검 시간을 정해 진행해야 합니다. [Cloud SQL 사설 IP 추가 동작](https://docs.cloud.google.com/sql/docs/mysql/configure-private-ip)

`terraform plan`에서 **2개 import, 기존 DB의 `private_network` 변경 2개, 신규 chat DB 생성 1개**를 확인하세요. 그 외 기존 DB 설정의 변경이나 교체·삭제가 계획에 나타나면 적용하지 말고 설정을 다시 맞춰야 합니다. v2 앱이 기존 데이터에 연결되고 이미지 조회·업로드가 동작하는지 확인한 뒤 트래픽을 전환하세요. 기존 운영 VM 삭제는 이 Terraform 코드에 포함되지 않았으며, 전환 후 별도로 처리해야 합니다.
