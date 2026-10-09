# 운영 환경

이 폴더가 운영 환경의 Terraform 실행 위치입니다. [`main.tf`](main.tf)는 운영 전용 [`modules/prod_modules`](../../modules/prod_modules)을 호출합니다. 기본값은 접두사 `mulo-v2`, `asia-northeast3` / `asia-northeast3-a`, 서브넷 `10.20.0.0/24`, Ubuntu 22.04 LTS `e2-medium`, VM당 30GB 디스크입니다. frontend·backend·chat VM 각 1대와 AI VM 2대가 생성됩니다.

운영은 전용 VPC, 사설 IP Cloud SQL(MySQL 2대·PostgreSQL 1대), 비공개 이미지 버킷, 글로벌 HTTPS 로드 밸런서, Cloud Tasks 큐를 사용합니다. 스테이징과 같은 규모로 구성하지만 리소스와 Terraform 상태는 별도입니다. [환경 공통 안내](../README.md)에서 전체 구조와 앱 연결 방식을 확인하세요.



```bash
# 저장소 루트에서 시작
cd environments/prod
cp terraform.tfvars.example terraform.tfvars
# terraform.tfvars의 실제 운영 값 확인·수정
gcloud auth application-default login
terraform init
terraform fmt -check
terraform validate
terraform plan -out=tfplan
# 계획 검토 후 실제 배포 시: terraform apply tfplan
```
