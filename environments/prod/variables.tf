# 리소스는 모두 삭제되었고, provider 설정에 필요한 값만 남깁니다.
# CI가 쓰는 TFVARS_<환경>에 남아 있는 다른 값은 "undeclared variable" 경고만 내고 무시됩니다.
variable "project_id" {
  description = "운영 환경의 GCP 프로젝트 ID"
  type        = string
}

variable "region" {
  type    = string
  default = "asia-northeast3"
}

variable "zone" {
  type    = string
  default = "asia-northeast3-a"
}
