# 개발 환경 (정리됨)

GCP 마이그레이션 완료로 이 환경이 관리하던 리소스는 모두 GCP에서 삭제했고, Terraform 코드와 state에서도 제거했습니다.

남은 파일은 state 위치(`backend.tf`)와 provider 설정(`versions.tf`, `variables.tf`)뿐입니다. `terraform plan`은 변경 없음이 정상입니다.
