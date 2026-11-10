# MULO Terraform

AWS 인프라 설정.

## 디렉터리

- `environments/dev`: 단일 EC2 개발 환경
- `environments/staging`: 스테이징 환경
- `environments/prod`: 운영 환경
- `modules/platform`: 운영·스테이징 공용 모듈

## 실행

Terraform 1.10 이상과 배포 대상 계정의 AWS 인증 정보가 필요합니다.
환경별 디렉터리에서 `terraform.tfvars`와 `backend.hcl`을 준비합니다.
`dev`와 `staging`은 각 디렉터리의 `.example` 파일을 참고합니다.

운영 환경:

```sh
cd environments/prod
terraform init -backend-config=backend.hcl
terraform plan
terraform apply
```

Kubernetes 설치와 애플리케이션 배포는 별도로 진행합니다.
