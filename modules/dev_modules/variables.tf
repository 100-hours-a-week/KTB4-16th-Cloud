# 개발 루트 모듈이 VM·디스크 사양을 전달하므로 이 파일의 기본값과 실제 배치 사양을 구분합니다.
variable "project_id" {
  type = string
}

variable "domain" {
  type = string
}

variable "name_prefix" {
  type = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,15}[a-z0-9]$", var.name_prefix))
    error_message = "name_prefix는 소문자/숫자/하이픈으로 된 2~17자여야 합니다."
  }
}

variable "region" {
  type = string
}

variable "zone" {
  type = string
}

variable "image_bucket_name" {
  type = string
}

variable "vm_machine_type" {
  type    = string
  default = "e2-small"
}

variable "vm_image" {
  type    = string
  default = "ubuntu-os-cloud/ubuntu-2204-lts"
}

variable "vm_boot_disk_size_gb" {
  type    = number
  default = 20
}

variable "startup_script" {
  description = "개발 VM에서 root로 실행할 초기 설정 스크립트"
  type        = string
}

variable "mysql_version" {
  type    = string
  default = "MYSQL_8_4"
}

variable "postgres_version" {
  type    = string
  default = "POSTGRES_18"
}

variable "sql_tier" {
  type    = string
  default = "db-g1-small"
}

variable "sql_deletion_protection" {
  type    = bool
  default = true
}

variable "runtime_enabled" {
  description = "true이면 개발 VM과 Cloud SQL을 켜고, false이면 중지합니다. 최초 생성은 true로 진행해야 합니다."
  type        = bool
  default     = true
}
