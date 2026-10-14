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

variable "monitoring_vm_machine_type" {
  description = "운영 모니터링 VM의 머신 타입"
  type        = string
  default     = "e2-medium"
}

variable "monitoring_vm_boot_disk_size_gb" {
  description = "운영 모니터링 VM의 부팅 디스크 크기(GB)"
  type        = number
  default     = 50
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
  description = "새 chat MySQL의 삭제 보호"
  type        = bool
  default     = true
}

variable "service_container_images" {
  description = "VM metadata의 app-image에 기록할 이미지 주소. Compose 실행은 별도로 구성합니다."
  type        = map(string)
  default = {
    ai       = "asia-northeast3-docker.pkg.dev/project-7b071b48-8637-467a-80d/ai/ai:1.5.0"
    backend  = "asia-northeast3-docker.pkg.dev/project-7b071b48-8637-467a-80d/backend/backend:1.7.0"
    frontend = "asia-northeast3-docker.pkg.dev/project-7b071b48-8637-467a-80d/frontend/frontend:1.7.1"
  }
  validation {
    condition     = alltrue([for key in keys(var.service_container_images) : contains(["frontend", "backend", "ai", "chat"], key)])
    error_message = "이미지 키는 frontend, backend, ai, chat만 가능합니다."
  }
}

variable "redis_vm_machine_type" {
  type    = string
  default = "e2-small"
}

variable "redis_vm_boot_disk_size_gb" {
  description = "독립 Redis VM의 부팅 디스크 크기(GB)"
  type        = number
  default     = 30
  validation {
    condition     = var.redis_vm_boot_disk_size_gb >= 20 && floor(var.redis_vm_boot_disk_size_gb) == var.redis_vm_boot_disk_size_gb
    error_message = "Redis 부팅 디스크 크기는 20GB 이상 정수여야 합니다."
  }
}
