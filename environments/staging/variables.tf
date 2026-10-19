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

variable "sql_deletion_protection" {
  type    = bool
  default = true
}

variable "runtime_enabled" {
  description = "모니터링·Redis VM과 Cloud SQL의 실행 상태. MIG는 mig-power.sh로 중지/시작합니다. 최초 배포는 true로 진행합니다."
  type        = bool
  default     = true
}

variable "monitoring_ports" {
  description = "모니터링 VM에서 Grafana·Prometheus가 수신하는 HTTP 포트"
  type = object({
    grafana    = number
    prometheus = number
  })
  default = {
    grafana    = 3000
    prometheus = 9090
  }

  validation {
    condition = alltrue([
      for port in values(var.monitoring_ports) : port >= 1 && port <= 65535 && floor(port) == port
    ]) && length(distinct(values(var.monitoring_ports))) == 2
    error_message = "모니터링 포트는 서로 다른 1~65535의 정수여야 합니다."
  }
}

variable "monitoring_vm_machine_type" {
  description = "스테이징 모니터링 VM의 머신 타입"
  type        = string
  default     = "e2-medium"
}

variable "monitoring_vm_boot_disk_size_gb" {
  description = "스테이징 모니터링 VM의 부팅 디스크 크기(GB)"
  type        = number
  default     = 30
}

# tfvars에서 이 맵을 지정하면 기본 맵 전체를 덮어씁니다. 누락한 서비스는 30GB를 사용합니다.
# 기존 디스크는 축소할 수 없으므로 크기를 줄이면 MIG가 새 VM과 디스크로 교체합니다.
variable "service_vm_boot_disk_sizes_gb" {
  description = "서비스별 앱 VM 부팅 디스크 크기(GB). 지정하지 않은 서비스는 30GB입니다."
  type        = map(number)
  default = {
    frontend = 20
    backend  = 20
    ai       = 20
    chat     = 20
  }
}

variable "service_container_images" {
  description = "app-image에 기록할 Docker 이미지 경로. 태그는 service_image_tags로 분리합니다."
  type        = map(string)
  default = {
    ai       = "asia-northeast3-docker.pkg.dev/project-7b071b48-8637-467a-80d/ai/ai"
    backend  = "asia-northeast3-docker.pkg.dev/project-7b071b48-8637-467a-80d/backend/backend"
    frontend = "asia-northeast3-docker.pkg.dev/project-7b071b48-8637-467a-80d/frontend/frontend"
  }
  validation {
    condition     = alltrue([for key in keys(var.service_container_images) : contains(["frontend", "backend", "ai", "chat"], key)])
    error_message = "이미지 키는 frontend, backend, ai, chat만 가능합니다."
  }
  validation {
    condition     = alltrue([for image in values(var.service_container_images) : image == "" || can(regex("^[^:@[:space:]]+/[^:@[:space:]]+$", image))])
    error_message = "이미지 경로에는 태그(:태그), digest(@값), 공백을 포함하지 마세요. 태그는 service_image_tags에 지정합니다."
  }
}

# chat은 이미지가 준비되면 경로와 최초 태그를 함께 추가합니다.
variable "service_image_tags" {
  description = "app-image-tag에 기록할 최초 태그. 이후 실제 배포 태그는 CD가 관리합니다."
  type        = map(string)
  default = {
    ai       = "1.8.0"
    backend  = "1.8.3"
    frontend = "1.9.1"
  }
  validation {
    condition = alltrue([
      for service, tag in var.service_image_tags :
      contains(["frontend", "backend", "ai", "chat"], service) && (tag == "" || can(regex("^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$", tag)))
    ])
    error_message = "태그 키는 frontend/backend/ai/chat이며 값은 올바른 Docker 태그여야 합니다."
  }
}

variable "service_max_rate_per_instance" {
  description = "내부 TCP LB와 MIG를 공유하는 외부 LB의 VM당 목표 RPS. 요청 차단 한도가 아닙니다."
  type        = map(number)
  default     = { backend = 30, ai = 30 }

  validation {
    condition = alltrue([
      for service in ["backend", "ai"] : try(var.service_max_rate_per_instance[service] > 0, false)
    ]) && alltrue([for service in keys(var.service_max_rate_per_instance) : contains(["backend", "ai"], service)])
    error_message = "backend와 ai의 VM당 목표 RPS를 양수로 지정해야 합니다."
  }
}

variable "internal_dns_domain" {
  description = "backend와 AI 내부 LB의 DNS 도메인. 마지막 점(.)을 포함합니다."
  type        = string
  default     = "staging.mulo.internal."
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]*\\.$", var.internal_dns_domain))
    error_message = "내부 DNS 도메인은 소문자·숫자·점·하이픈으로 작성하고 점(.)으로 끝나야 합니다."
  }
}

variable "redis_vm_machine_type" {
  type    = string
  default = "e2-medium"
}

variable "redis_vm_boot_disk_size_gb" {
  description = "독립 Redis VM의 부팅 디스크 크기(GB)"
  type        = number
  default     = 20
  validation {
    condition     = var.redis_vm_boot_disk_size_gb >= 20 && floor(var.redis_vm_boot_disk_size_gb) == var.redis_vm_boot_disk_size_gb
    error_message = "Redis 부팅 디스크 크기는 20GB 이상 정수여야 합니다."
  }
}
