variable "project_id" {
  description = "운영 환경을 배포할 GCP 프로젝트 ID"
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "실제 운영 GCP 프로젝트 ID(6~30자, 소문자·숫자·하이픈)를 입력해야 합니다."
  }
}

variable "domain" {
  description = "운영 환경의 HTTPS 도메인"
  type        = string
}

variable "image_bucket_name" {
  description = "전역에서 유일한 운영 이미지 버킷 이름"
  type        = string
}

variable "name_prefix" {
  type    = string
  default = "mulo-v2"

  validation {
    condition     = !can(regex("-staging$", var.name_prefix))
    error_message = "운영 접두사는 스테이징 접두사와 구분되도록 -staging으로 끝나면 안 됩니다."
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
  default = "10.20.0.0/24"
}

variable "vm_machine_type" {
  type    = string
  default = "e2-medium"
}

variable "vm_image" {
  type    = string
  default = "ubuntu-os-cloud/ubuntu-2204-lts"
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
  description = "서비스별 선택적 VM 시작 스크립트. ai 스크립트는 AI VM 적용됩니다."
  type        = map(string)
  default     = {}
}

variable "mysql_version" {
  type    = string
  default = "MYSQL_8_4"
}

variable "postgres_version" {
  type    = string
  default = "POSTGRES_16"
}

variable "sql_tier" {
  type    = string
  default = "db-g1-small"
}

variable "sql_deletion_protection" {
  type    = bool
  default = true
}
