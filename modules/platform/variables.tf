variable "config" {
  description = "AWS 인프라와 워커 자동 가입 입력. OS·런타임·kubeadm 설치는 AMI에서 준비하고, Helm·앱 배포는 별도로 진행합니다."
  type = object({
    account_id      = string
    ami_id          = string
    vpc_cidr        = string
    azs             = list(string)
    certificate_arn = optional(string)
    # HTTPS 리스너가 붙일 Strict-Transport-Security 값. null이면 헤더를 붙이지 않습니다.
    hsts_header_value = optional(string)
    public_hosts      = list(string)
    platform_services = optional(map(object({
      hostname     = string
      namespace    = string
      service_name = string
      service_port = number
    })), {})
    platform_gateway = optional(object({
      name          = optional(string, "mulo-gateway")
      namespace     = optional(string, "edge")
      listener_name = optional(string, "http")
    }), {})
    single_nat_gateway  = optional(bool, false)
    control_plane_type  = optional(string, "t3.medium")
    control_plane_count = optional(number, 3)
    # CP 루트 볼륨 크기(GiB). CP AMI의 스냅샷 크기 이상이어야 합니다. etcd는 별도 볼륨을 씁니다.
    control_plane_root_gb      = optional(number, 50)
    enable_deletion_protection = optional(bool, true)
    envoy_node_port            = optional(number, 30080)
    envoy_health_path          = optional(string, "/healthz")
    # 초기 구축에서 EBS CSI가 system EC2의 IAM 역할을 사용하도록 명시적으로 켭니다.
    ebs_csi_use_node_role = optional(bool, false)
    # Loki의 S3 접근과 Vault의 KMS auto-unseal도 초기에는 system EC2 역할로 처리합니다.
    loki_use_node_role = optional(bool, false)
    # backend(general=api 노드)가 EC2 역할로 images 버킷에 접근한다. 켜면 api 노드 IMDS hop limit도 2가 된다.
    images_s3_use_node_role = optional(bool, false)
    vault_kms_use_node_role = optional(bool, false)
    # 운영 도구(argocd·grafana·prometheus) 도메인에 접근할 수 있는 IP 대역입니다. 나머지는 ALB가 403으로 막습니다.
    admin_allowed_cidrs = optional(list(string), [])
    # WAF가 IP 하나당 5분 동안 허용하는 요청 수입니다. 넘으면 차단합니다.
    # null이면 IP별 요청 수 제한 규칙을 만들지 않습니다(공통 관리형 규칙은 유지).
    # 2026-11-23: 5분 2,000건은 같은 공인 IP를 쓰는 사용자(와이파이·통신사 망)와 부하테스트를 막아서 끕니다.
    waf_rate_limit = optional(number)
    # route53_zone과 그 아래 서브도메인용 ACM 인증서를 DNS 검증으로 요청합니다.
    request_certificate = optional(bool, false)
    # etcd·Vault 백업 버킷에서 스냅샷을 보관할 일수입니다.
    backup_retention_days = optional(number, 30)
    # DB 비밀번호를 바꿀 때 1씩 올립니다. 이 값이 바뀔 때만 SSM의 /<이름>/db/<DB>/master-password 값이 RDS에 적용됩니다.
    db_password_version = optional(number, 1)
    # RDS 변경(크기, Multi-AZ 등)을 정비 시간까지 미루지 않고 바로 반영합니다.
    rds_apply_immediately = optional(bool, false)
    # RDS를 지울 때 최종 스냅샷을 건너뜁니다. 환경을 통째로 지울 때만 true로 둡니다.
    skip_final_snapshot = optional(bool, false)
    # CP마다 붙이는 etcd 전용 gp3 볼륨 크기(GiB)입니다. etcd 기본 DB 한도는 2GiB입니다.
    etcd_volume_gb = optional(number, 20)
    # Cluster Autoscaler가 system EC2 역할로 ASG 크기를 바꾸게 합니다.
    cluster_autoscaler_use_node_role = optional(bool, false)
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
    route53_zone = optional(string)
    # ALB를 가리키지 않는 기타 레코드(메일 MX, SPF TXT 등). 키는 Terraform 안에서만 쓰는 이름입니다.
    route53_extra_records = optional(map(object({
      name    = string
      type    = string
      ttl     = optional(number, 300)
      records = list(string)
    })), {})
    enable_datasync_iam = optional(bool, false)
    workers = map(object({
      availability_zones = list(string)
      instance_type      = string
      # CP와 다른 워커 전용 이미지를 지정합니다. 생략 시 config.ami_id를 사용합니다.
      ami_id  = optional(string)
      min     = number
      desired = number
      # 역할 전체의 최대 대수입니다. 여러 AZ를 쓰면 local.worker_groups에서 분배합니다.
      max = optional(number)
      # 평소에는 0대로 비워 두는 예비 AZ. availability_zones의 AZ가 죽으면 Cluster Autoscaler가 여기서 노드를 띄웁니다.
      # min·desired 0, max는 기본 AZ 한 곳의 최대 대수와 같습니다.
      standby_availability_zones = optional(list(string), [])
      root_volume_gb             = optional(number, 50)
      # IMDS 응답 홉 제한. Pod가 노드 EC2 역할(S3 등)을 쓰는 그룹은 2가 필요합니다. 생략하면 기존 규칙(system·api는 역할 사용 여부에 따라 2, 나머지 1)을 따릅니다.
      imds_hop_limit = optional(number)
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
      # DB 파라미터 그룹에 넣을 값. 기본은 pending-reboot라 apply 후 재부팅해야 반영됩니다.
      parameters = optional(map(string), {})
      # 재부팅 없이 바로 반영할 동적 파라미터 이름. 정적 파라미터를 넣으면 AWS가 거부합니다.
      immediate_parameters = optional(set(string), [])
      }
      )), {
      }
    )
    # GitHub Actions OIDC로 ECR에 push할 저장소. 키는 ecr_repositories 항목, 값은 "owner/name" 형식의 GitHub 저장소입니다.
    # 신뢰 정책은 branch 한 곳의 push 워크플로(sub = repo:<owner/name>:ref:refs/heads/<branch>)만 허용합니다.
    # 조직이 OIDC sub에 숫자 ID를 넣도록 설정돼 있으면(sub = repo:<owner>@<owner_id>/<name>@<repo_id>:ref:...)
    # owner_id와 repository_ids(키는 ecr_push_repositories와 같음)를 채웁니다. 채운 저장소는 두 형식을 모두 허용합니다.
    github_actions = optional(object({
      branch                = optional(string, "main")
      ecr_push_repositories = map(string)
      owner_id              = optional(string)
      repository_ids        = optional(map(string), {})
      }
    ))

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
      for w in values(var.config.workers) : length(w.availability_zones) >= 1 && length(distinct(w.availability_zones)) == length(w.availability_zones) && alltrue([for az in w.availability_zones : contains(var.config.azs, az)]) && alltrue([for az in w.standby_availability_zones : contains(var.config.azs, az) && !contains(w.availability_zones, az)]) && length(distinct(w.standby_availability_zones)) == length(w.standby_availability_zones) && w.min >= length(w.availability_zones) && w.min <= w.desired && floor(w.min) == w.min && floor(w.desired) == w.desired && w.root_volume_gb >= 20 && (w.max == null ? true : w.max >= w.desired && floor(w.max) == w.max) && (w.ami_id == null ? true : can(regex("^ami-([a-f0-9]{8}|[a-f0-9]{17})$", w.ami_id)))
    ])
    error_message = "각 역할에 유효한 서로 다른 AZ, AZ 수 이상인 정수 min <= desired, 루트 20GiB 이상이 필요합니다. max 입력 시 desired 이상의 정수, ami_id 입력 시 유효한 AMI ID여야 합니다."
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
    condition = alltrue([
      for service in values(var.config.platform_services) :
      length(service.hostname) <= 128 && length(split(".", service.hostname)) > 1 && alltrue([
        for label in split(".", service.hostname) :
        length(label) <= 63 && can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", label))
      ])
    ])
    error_message = "platform_services.hostname에는 ALB 제한인 128자 이내의 소문자 도메인을 스킴·포트·경로·와일드카드 없이 지정하세요."
  }

  validation {
    condition = (
      length(distinct([for service in values(var.config.platform_services) : service.hostname])) == length(var.config.platform_services) &&
      alltrue([for service in values(var.config.platform_services) : !contains(var.config.public_hosts, service.hostname)])
    )
    error_message = "운영 도구 도메인은 서로 달라야 하며 public_hosts와 중복될 수 없습니다."
  }

  validation {
    condition = alltrue(concat(
      [for name, service in var.config.platform_services :
        alltrue([for value in [name, service.namespace, service.service_name] :
          length(value) <= 63 && can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", value))
        ]) && service.service_port >= 1 && service.service_port <= 65535 && floor(service.service_port) == service.service_port
      ],
      [for value in [var.config.platform_gateway.name, var.config.platform_gateway.namespace, var.config.platform_gateway.listener_name] :
        length(value) <= 63 && can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", value))
      ]
    ))
    error_message = "운영 도구·Gateway의 이름은 63자 이내 소문자 DNS 라벨, 서비스 포트는 1~65535 정수여야 합니다."
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
      alltrue([for host in concat(var.config.public_hosts, [for service in values(var.config.platform_services) : service.hostname]) : host == trimsuffix(var.config.route53_zone, ".") || endswith(host, ".${trimsuffix(var.config.route53_zone, ".")}")])
    )
    error_message = "Route 53 공개 호스티드 존은 앱과 운영 도구 호스트를 모두 포함하는 도메인으로 지정하세요."
  }

  validation {
    condition = length(var.config.platform_services) == 0 || (
      length(var.config.admin_allowed_cidrs) >= 1 && length(var.config.admin_allowed_cidrs) <= 4 &&
      alltrue([for cidr in var.config.admin_allowed_cidrs : can(cidrnetmask(cidr)) && !endswith(cidr, "/0")])
    )
    error_message = "운영 도구 도메인을 열려면 admin_allowed_cidrs에 허용할 IPv4 CIDR을 1~4개 지정하세요. 0.0.0.0/0은 쓸 수 없습니다(ALB 규칙 조건 값 한도 5개 중 1개는 호스트 이름)."
  }

  validation {
    condition     = var.config.waf_rate_limit == null ? true : var.config.waf_rate_limit >= 10 && floor(var.config.waf_rate_limit) == var.config.waf_rate_limit
    error_message = "WAF 요청 제한은 null(끄기) 또는 10 이상의 정수여야 합니다."
  }

  validation {
    condition     = !var.config.request_certificate || var.config.route53_zone != null
    error_message = "ACM 인증서를 요청하려면 DNS 검증 레코드를 만들 route53_zone이 필요합니다."
  }

  validation {
    condition     = var.config.etcd_volume_gb >= 8 && floor(var.config.etcd_volume_gb) == var.config.etcd_volume_gb
    error_message = "etcd 볼륨은 8GiB 이상의 정수여야 합니다."
  }

  validation {
    condition     = var.config.backup_retention_days >= 1 && floor(var.config.backup_retention_days) == var.config.backup_retention_days
    error_message = "백업 보관 일수는 1 이상의 정수여야 합니다."
  }

  validation {
    condition     = length(var.config.ecr_repositories) > 0
    error_message = "ECR 저장소는 하나 이상 필요합니다."
  }

  validation {
    condition = var.config.github_actions == null ? true : alltrue([
      for ecr, repo in var.config.github_actions.ecr_push_repositories :
      contains(var.config.ecr_repositories, ecr) && can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", repo))
    ])
    error_message = "github_actions.ecr_push_repositories의 키는 ecr_repositories에 있는 이름이어야 하고, 값은 owner/name 형식의 GitHub 저장소여야 합니다."
  }

  validation {
    condition = var.config.github_actions == null ? true : (
      length(var.config.github_actions.repository_ids) == 0 ? true : (
        can(regex("^[0-9]+$", var.config.github_actions.owner_id)) && alltrue([
          for k, id in var.config.github_actions.repository_ids :
          contains(keys(var.config.github_actions.ecr_push_repositories), k) && can(regex("^[0-9]+$", id))
        ])
      )
    )
    error_message = "github_actions.repository_ids를 쓰려면 숫자 owner_id가 필요하고, 키는 ecr_push_repositories에 있는 이름, 값은 숫자 저장소 ID여야 합니다."
  }
}


variable "environment" {
  type = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "환경은 dev/staging/prod 중 하나입니다."
  }
}

variable "region" {
  type = string
}

locals {
  name = "mulo-v3-${var.environment}"
  azs = {
    for index, az in var.config.azs : az => index
  }

  control_planes = {
    for index in range(var.config.control_plane_count) : tostring(index + 1) => var.config.azs[index]
  }


  worker_groups = {
    for item in flatten([
      for role, worker in var.config.workers : concat([
        for index, az in worker.availability_zones : {
          key     = "${role}-${az}"
          role    = role
          az      = az
          min     = floor(worker.min / length(worker.availability_zones)) + (index < worker.min % length(worker.availability_zones) ? 1 : 0)
          desired = floor(worker.desired / length(worker.availability_zones)) + (index < worker.desired % length(worker.availability_zones) ? 1 : 0)
          # 정수 몫을 각 AZ에 배정하고 남은 수를 앞쪽 AZ부터 한 대씩 더 배정합니다.
          max = floor(coalesce(worker.max, worker.desired) / length(worker.availability_zones)) + (index < coalesce(worker.max, worker.desired) % length(worker.availability_zones) ? 1 : 0)
        }
        ],
        # 예비 AZ: 평소 0대. 장애 때 CA가 기본 AZ 한 곳의 최대 대수까지 늘립니다.
        [
          for az in worker.standby_availability_zones : {
            key     = "${role}-${az}"
            role    = role
            az      = az
            min     = 0
            desired = 0
            max     = ceil(coalesce(worker.max, worker.desired) / length(worker.availability_zones))
          }
      ])
    ]) : item.key => item
  }

  cluster_tag = "kubernetes.io/cluster/${local.name}"
}

resource "terraform_data" "guardrails" {
  lifecycle {
    precondition {
      condition     = var.environment == "dev" || (var.config.control_plane_count == 3 && !var.config.single_nat_gateway)
      error_message = "prod/staging은 CP 3대와 AZ별 NAT가 필요합니다. 구축 중에는 역할별 워커 1대와 단일 AZ를 허용합니다."
    }

    precondition {
      condition     = alltrue([for az in var.config.azs : startswith(az, var.region)])
      error_message = "모든 AZ는 provider region에 속해야 합니다."
    }

  }
}

