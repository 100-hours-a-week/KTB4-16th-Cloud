variable "config" {
  description = "AWS 인프라 입력. OS 설치, kubeadm, Helm, 앱 배포는 이 모듈의 범위가 아닙니다."
  type = object({
    account_id                 = string
    ami_id                     = string
    vpc_cidr                   = string
    azs                        = list(string)
    certificate_arn            = string
    public_hosts               = list(string)
    single_nat_gateway         = optional(bool, false)
    control_plane_type         = optional(string, "t3.medium")
    control_plane_count        = optional(number, 3)
    enable_deletion_protection = optional(bool, true)
    envoy_node_port            = optional(number, 30080)
    envoy_health_path          = optional(string, "/healthz")
    # 이전 기간의 GCP 사설 연결입니다. 실제 피어 IP와 ASN은 환경 입력에서 지정합니다.
    migration_vpn = optional(object({
      gcp_app_cidrs      = set(string)
      gcp_database_cidrs = set(string)
      gcp_interface_ips = object({
        interface0 = string
        interface1 = string
      })
      gcp_bgp_asn = number
      aws_bgp_asn = optional(number, 64512)
    }))
    route53_zone        = optional(string)
    enable_datasync_iam = optional(bool, false)
    workers = map(object({
      availability_zones = list(string)
      instance_type      = string
      min                = number
      desired            = number
      root_volume_gb     = optional(number, 50)
      }
    ))

    interface_endpoints = optional(set(string), ["ssm", "ssmmessages", "sts", "ec2", "autoscaling"])
    ecr_repositories    = optional(set(string), ["frontend", "backend", "ai", "chat"])
    databases = optional(map(object({
      engine                = string
      engine_version        = string
      instance_class        = optional(string, "db.t4g.medium")
      database_name         = string
      username              = optional(string, "mulo_admin")
      allocated_storage     = optional(number, 50)
      max_allocated_storage = optional(number, 200)
      multi_az              = optional(bool, true)
      snapshot_identifier   = optional(string)
      }
      )), {
      }
    )
    oidc = optional(object({
      url         = string
      thumbprints = optional(list(string), [])
      }
    ))
    }
  )
  validation {
    condition     = can(regex("^[0-9]{12}$", var.config.account_id)) && can(regex("^ami-[a-f0-9]{8,17}$", var.config.ami_id))
    error_message = "12자리 AWS 계정 ID와 해당 리전의 x86_64 AMI ID를 입력하세요."
  }

  validation {
    condition     = length(var.config.azs) == 3 && length(distinct(var.config.azs)) == 3 && can(cidrsubnet(var.config.vpc_cidr, 8, 34)) && can(regex("/16$", var.config.vpc_cidr))
    error_message = "서로 다른 AZ 3개와 /16 VPC CIDR이 필요합니다. 서브넷 /24는 자동 분할됩니다."
  }

  validation {
    condition     = contains([1, 3], var.config.control_plane_count)
    error_message = "Control Plane은 1 또는 3대만 지원합니다."
  }

  validation {
    condition = toset(keys(var.config.workers)) == toset(["system", "api", "chat", "ai"]) && alltrue([
      for w in values(var.config.workers) : length(w.availability_zones) >= 1 && length(distinct(w.availability_zones)) == length(w.availability_zones) && alltrue([for az in w.availability_zones : contains(var.config.azs, az)]) && w.min >= length(w.availability_zones) && w.min <= w.desired && floor(w.min) == w.min && floor(w.desired) == w.desired && w.root_volume_gb >= 20
    ])
    error_message = "각 역할에 서로 다른 유효 AZ를 지정하고, min은 AZ 수 이상이며 정수 min <= desired와 루트 20GiB 이상을 만족해야 합니다. ASG 최대 대수는 desired와 같습니다."
  }

  validation {
    condition     = var.config.envoy_node_port >= 30000 && var.config.envoy_node_port <= 32767 && floor(var.config.envoy_node_port) == var.config.envoy_node_port && startswith(var.config.envoy_health_path, "/")
    error_message = "Envoy NodePort는 30000~32767 정수, health path는 /로 시작해야 합니다."
  }

  validation {
    condition     = length(var.config.public_hosts) > 0 && length(var.config.public_hosts) <= 3 && alltrue([for host in var.config.public_hosts : can(regex("^[a-z0-9][a-z0-9.-]+$", host))])
    error_message = "public_hosts에는 정확한 호스트명을 1~3개 지정하세요."
  }

  validation {
    condition     = alltrue([for db in values(var.config.databases) : contains(["mysql", "postgres"], db.engine) && db.allocated_storage >= 20 && db.max_allocated_storage >= db.allocated_storage])
    error_message = "DB 엔진은 mysql/postgres이며 최대 디스크는 초기 크기(최소 20GiB) 이상이어야 합니다."
  }

  validation {
    condition     = var.config.oidc == null ? true : startswith(var.config.oidc.url, "https://") && !endswith(var.config.oidc.url, "/")
    error_message = "OIDC issuer는 끝에 /가 없는 공개 HTTPS URL이어야 합니다."
  }

  validation {
    condition = var.config.migration_vpn == null ? true : (
      length(var.config.migration_vpn.gcp_app_cidrs) > 0 && length(var.config.migration_vpn.gcp_database_cidrs) > 0 &&
      alltrue([for cidr in setunion(var.config.migration_vpn.gcp_app_cidrs, var.config.migration_vpn.gcp_database_cidrs) : can(cidrnetmask(cidr)) && cidr != "0.0.0.0/0"]) &&
      alltrue([for ip in values(var.config.migration_vpn.gcp_interface_ips) : can(cidrnetmask("${ip}/32"))]) &&
      var.config.migration_vpn.gcp_interface_ips.interface0 != var.config.migration_vpn.gcp_interface_ips.interface1 &&
      var.config.migration_vpn.gcp_bgp_asn != var.config.migration_vpn.aws_bgp_asn &&
      alltrue([for asn in [var.config.migration_vpn.gcp_bgp_asn, var.config.migration_vpn.aws_bgp_asn] : floor(asn) == asn && ((asn >= 64512 && asn <= 65534) || (asn >= 4200000000 && asn <= 4294967294))])
    )
    error_message = "VPN에는 GCP 앱·DB IPv4 CIDR, 서로 다른 HA VPN 인터페이스 IP 2개, 서로 다른 유효한 사설 BGP ASN이 필요합니다."
  }

  validation {
    condition = var.config.route53_zone == null ? true : (
      can(regex("^[a-z0-9][a-z0-9.-]+[.][a-z]{2,}[.]?$", var.config.route53_zone)) &&
      alltrue([for host in var.config.public_hosts : host == trimsuffix(var.config.route53_zone, ".") || endswith(host, ".${trimsuffix(var.config.route53_zone, ".")}")])
    )
    error_message = "Route 53 공개 호스티드 존은 앱 호스트를 포함하는 도메인으로 지정하세요."
  }

  validation {
    condition     = length(var.config.ecr_repositories) > 0
    error_message = "ECR 저장소는 하나 이상 필요합니다."
  }
}


variable "region" {
  type    = string
  default = "ap-northeast-2"
}

