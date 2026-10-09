variable "project_id" {
  description = "개발 환경을 배포할 GCP 프로젝트 ID"
  type        = string
}

variable "domain" {
  description = "개발 VM의 Nginx와 Certbot이 사용할 HTTPS 도메인"
  type        = string
}

variable "image_bucket_name" {
  description = "전역에서 유일한 개발 이미지 버킷 이름"
  type        = string
}

variable "name_prefix" {
  type    = string
  default = "mulo-v2-dev"
}

variable "region" {
  type    = string
  default = "asia-northeast3"
}

variable "zone" {
  type    = string
  default = "asia-northeast3-a"
}

variable "sql_deletion_protection" {
  type    = bool
  default = true
}

variable "runtime_enabled" {
  description = "개발 VM과 Cloud SQL의 실행 상태. 최초 배포는 true, 사용하지 않을 때 false로 바꿔 적용합니다."
  type        = bool
  default     = true
}
