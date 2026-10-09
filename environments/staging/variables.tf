variable "project_id" {
  description = "스테이징 환경을 배포할 GCP 프로젝트 ID"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "실제 스테이징 GCP 프로젝트 ID(6~30자, 소문자·숫자·하이픈)를 입력해야 합니다."
  }
}

variable "domain" {
  description = "스테이징 환경의 HTTPS 도메인"
  type        = string
}

variable "image_bucket_name" {
  description = "전역에서 유일한 스테이징 이미지 버킷 이름"
  type        = string
}

variable "name_prefix" {
  type    = string
  default = "mulo-v2-staging"

  validation {
    condition     = can(regex("-staging$", var.name_prefix))
    error_message = "같은 프로젝트에서 운영 리소스와 구분되도록 스테이징 접두사는 -staging으로 끝나야 합니다."
  }
}

variable "region" {
  type    = string
  default = "asia-northeast3"
}

variable "zone" {
  type    = string
  default = "asia-northeast3-a"
}

variable "subnet_cidr" {
  type    = string
  default = "10.21.0.0/24"
}

variable "service_ports" {
  type = object({
    frontend = number
    ai       = number
    backend  = number
    chat     = number
  })
  default = {
    frontend = 3000
    ai       = 8000
    backend  = 8080
    chat     = 8081
  }
}

variable "health_paths" {
  type = object({
    frontend = string
    ai       = string
    backend  = string
    chat     = string
  })
  default = {
    frontend = "/"
    ai       = "/health"
    backend  = "/actuator/health"
    chat     = "/health"
  }
}

variable "startup_scripts" {
  type    = map(string)
  default = {}
}

variable "sql_deletion_protection" {
  type    = bool
  default = true
}

variable "runtime_enabled" {
  description = "스테이징 VM과 Cloud SQL의 실행 상태. 최초 배포는 true, 사용하지 않을 때 false로 바꿔 적용합니다."
  type        = bool
  default     = true
}
