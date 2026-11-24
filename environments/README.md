# 환경 공통 구성

GCP 마이그레이션 완료로 dev·staging·prod 환경의 리소스(VM·MIG·LB·Cloud SQL·DNS·VPC·VPN·시크릿·서비스 계정 등)는 모두 삭제했고, Terraform 코드와 state에서도 제거했습니다.

각 환경 폴더에는 state 위치(`backend.tf`)와 provider 설정만 남아 있습니다. state 버킷과 팀원 연결 방법은 [팀 공유 state 안내](STATE.md)를 참고합니다.

## 그대로 두는 GCP 리소스

Terraform CI(`.github/workflows/terraform-*.yml`)가 사용하므로 지우지 않습니다. 이 리소스들은 Terraform 코드로 관리하지 않습니다.

| 리소스 | 용도 |
| --- | --- |
| WIF 풀 `github-pool` | GitHub Actions 인증 |
| 서비스 계정 `terraform-plan`, `terraform-apply` | CI plan·apply 실행 |
| GCS 버킷 `mulo-v2-tfstate-953840519216` | 환경별 Terraform state |

전체 `terraform destroy`나 위 리소스 삭제는 CI를 깨뜨리므로 하지 않습니다.
