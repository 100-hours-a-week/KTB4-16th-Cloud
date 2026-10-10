variable "project_id" {
  description = "이미 생성된 GCP 프로젝트 ID"
  type        = string
}

variable "domain" {
  description = "로드밸런서의 HTTPS 도메인. 적용 후 A 레코드를 출력된 IP로 연결해야 인증서가 발급됩니다."
  type        = string
}

variable "image_bucket_name" {
  description = "재사용할 기존 운영 이미지 버킷 이름"
  type        = string
}

variable "existing_backend_mysql_instance_name" {
  description = "재사용할 기존 운영 backend MySQL Cloud SQL 인스턴스 이름"
  type        = string
}

variable "existing_ai_postgres_instance_name" {
  description = "재사용할 기존 운영 AI PostgreSQL Cloud SQL 인스턴스 이름"
  type        = string
}

variable "name_prefix" {
  description = "GCP 리소스 이름"
  type        = string
  default     = "mulo-v2"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,15}[a-z0-9]$", var.name_prefix))
    error_message = "name_prefix는 소문자/숫자/하이픈으로 된 2~17자여야 합니다."
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

variable "vm_boot_disk_size_gb" {
  description = "각 VM의 부팅 디스크 크기(GB)"
  type        = number
  default     = 30
}

variable "ai_vm_count" {
  description = "운영 AI VM 수. 현재 운영 환경은 2대를 사용합니다."
  type        = number
  default     = 2

  validation {
    condition     = contains([1, 2], var.ai_vm_count)
    error_message = "ai_vm_count는 1 또는 2여야 합니다."
  }
}

variable "use_default_vpc" {
  description = "기존 default VPC와 리전 서브넷을 사용합니다. false이면 전용 VPC를 생성합니다."
  type        = bool
  default     = false
}

variable "enable_cloud_tasks" {
  description = "Cloud Tasks 큐와 관련 IAM/서비스 계정을 생성합니다."
  type        = bool
  default     = true
}

variable "vm_image" {
  type    = string
  default = "ubuntu-os-cloud/ubuntu-2204-lts"
}


variable "service_ports" {
  description = "각 VM에서 애플리케이션이 수신할 HTTP 포트"
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
  description = "로드밸런서가 각 애플리케이션에서 호출할 200 응답 경로"
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

variable "bootstrap_script" {
  description = "모든 서비스 VM에 공통으로 실행할 초기 설정 스크립트"
  type        = string
}

variable "mysql_version" {
  description = "새 chat MySQL의 버전"
  type        = string
  default     = "MYSQL_8_4"
}

variable "sql_tier" {
  description = "새 chat MySQL의 머신 티어"
  type        = string
  default     = "db-g1-small"
}

variable "sql_deletion_protection" {
  description = "새 chat MySQL에 적용할 Terraform 및 GCP 삭제 보호"
  type        = bool
  default     = true
}
