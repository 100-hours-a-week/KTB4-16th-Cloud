# 환경의 실제 기본값은 environments/staging/main.tf와 variables.tf에서 전달됩니다.
variable "project_id" {
  description = "이미 생성된 GCP 프로젝트 ID"
  type        = string
}

variable "domain" {
  description = "로드밸런서의 HTTPS 도메인. 적용 후 A 레코드를 출력된 IP로 연결해야 인증서가 발급됩니다."
  type        = string
}

variable "image_bucket_name" {
  description = "전역에서 유일한 이미지 버킷 이름"
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

variable "service_vm_boot_disk_sizes_gb" {
  description = "서비스별 앱 VM 부팅 디스크 크기(GB). 미지정 서비스는 vm_boot_disk_size_gb를 사용합니다."
  type        = map(number)
  default     = {}
  validation {
    condition = alltrue([
      for service, size in var.service_vm_boot_disk_sizes_gb :
      contains(["frontend", "backend", "ai", "chat"], service) && size >= 20 && floor(size) == size
    ])
    error_message = "서비스는 frontend/backend/ai/chat이며 디스크 크기는 20GB 이상 정수여야 합니다."
  }
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

  validation {
    condition     = var.monitoring_vm_boot_disk_size_gb >= 20
    error_message = "모니터링 VM의 부팅 디스크는 20GB 이상이어야 합니다."
  }
}

variable "ai_vm_count" {
  description = "스테이징 AI VM 수. 현재 스테이징 환경은 2대를 사용합니다."
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
  description = "메타데이터와 Secret Manager로 앱을 실행하는 MIG 부팅 스크립트"
  type        = string
}

variable "base_bootstrap_script" {
  description = "독립 Redis·모니터링 VM의 기존 기반 설치 스크립트"
  type        = string
}

variable "shutdown_script" {
  description = "앱 VM 종료 시 컨테이너를 정상 종료하는 스크립트"
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
  description = "Terraform 및 GCP의 Cloud SQL 삭제 보호"
  type        = bool
  default     = true
}

variable "runtime_enabled" {
  description = "모니터링·Redis VM과 Cloud SQL의 실행 상태. 앱 MIG는 mig-power.sh로 중지/시작합니다. 최초 생성은 true로 진행합니다."
  type        = bool
  default     = true
}

variable "service_container_images" {
  description = "app-image에 기록할 Docker 이미지 경로. 태그는 service_image_tags로 분리합니다."
  type        = map(string)
  default     = {}
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
  default     = {}
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
    error_message = "Redis 부팅 디스크 크기는 20GB여야 합니다."
  }
}
