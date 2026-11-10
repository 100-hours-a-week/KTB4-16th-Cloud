mock_provider "aws" {
  mock_data "aws_partition" { defaults = { partition = "aws" } }
  mock_data "aws_ami" { defaults = { architecture = "x86_64", root_device_type = "ebs", root_device_name = "/dev/sda1" } }
}
variables {
  environment = "prod"
  region      = "ap-northeast-2"
  config = {
    account_id      = "123456789012"
    ami_id          = "ami-0123456789abcdef0"
    vpc_cidr        = "10.60.0.0/16"
    azs             = ["ap-northeast-2a", "ap-northeast-2b", "ap-northeast-2c"]
    certificate_arn = "arn:aws:acm:ap-northeast-2:123456789012:certificate/11111111-1111-1111-1111-111111111111"
    public_hosts    = ["mulo.example.com"]
    workers = {
      system = { availability_zones = ["ap-northeast-2c"], instance_type = "m7i.large", min = 1, desired = 1 }
      api    = { availability_zones = ["ap-northeast-2a"], instance_type = "m7i.large", min = 1, desired = 1 }
      chat   = { availability_zones = ["ap-northeast-2b"], instance_type = "m7i.large", min = 1, desired = 1 }
      ai     = { availability_zones = ["ap-northeast-2b"], instance_type = "m7i.xlarge", min = 1, desired = 1 }
    }
    databases = {
      api  = { engine = "mysql", engine_version = "8.4", database_name = "mulo" }
      chat = { engine = "mysql", engine_version = "8.4", database_name = "mulo_chat" }
      ai   = { availability_zones = ["ap-northeast-2a", "ap-northeast-2b"], engine = "postgres", engine_version = "18", database_name = "mulo_ai" }
    }
    migration_vpn = {
      gcp_app_cidrs      = ["10.20.0.0/24"]
      gcp_database_cidrs = ["10.91.0.0/16"]
      gcp_interface_ips  = { interface0 = "203.0.113.10", interface1 = "203.0.113.20" }
      gcp_bgp_asn        = 64514
      aws_bgp_asn        = 64512
    }
    route53_zone        = "example.com"
    enable_datasync_iam = true
    oidc                = { url = "https://oidc.example.com" }
  }
}
run "production_boundaries" {
  command = plan
  assert {
    condition     = length(aws_vpn_gateway.migration) == 1 && length(aws_customer_gateway.gcp) == 2 && length(aws_vpn_connection.gcp) == 2 && alltrue([for c in aws_vpn_connection.gcp : !c.static_routes_only && c.tunnel1_ike_versions == toset(["ikev2"]) && c.tunnel2_ike_versions == toset(["ikev2"]) && c.tunnel1_phase1_encryption_algorithms == toset(["AES256"]) && c.tunnel2_phase1_encryption_algorithms == toset(["AES256"])])
    error_message = "GCP HA VPN 두 인터페이스에 VGW·CGW 2개·동적 VPN 연결 2개(터널 4개), IKEv2 단일 제안이 필요합니다."
  }
  assert {
    condition     = toset(keys(aws_vpn_gateway_route_propagation.migration)) == toset(["private-ap-northeast-2a", "private-ap-northeast-2b", "private-ap-northeast-2c", "data"])
    error_message = "VPN BGP 경로는 Private 라우팅 테이블 3개와 Data에만 전파해야 합니다."
  }
  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.gcp_database) == 4 && length(aws_vpc_security_group_egress_rule.gcp_replication) == 2 && alltrue([for rule in aws_vpc_security_group_egress_rule.gcp_replication : rule.cidr_ipv4 == "10.91.0.0/16" && contains([3306, 5432], rule.from_port) && rule.from_port == rule.to_port])
    error_message = "RDS의 GCP 대역 인바운드와 Cloud SQL로 먼저 접속하는 3306·5432 아웃바운드가 필요합니다."
  }
  assert {
    condition     = local.node_rules["mysql-ai"].source == "ai" && local.node_rules["mysql-ai"].from == 3306 && local.node_rules["postgres-api"].source == "api" && local.node_rules["postgres-api"].from == 5432 && !aws_lb_target_group.api.preserve_client_ip
    error_message = "AI→MySQL·API→PostgreSQL 교차 접근과 NLB hairpin 방지 설정을 유지해야 합니다."
  }
  assert {
    condition     = length(aws_route53_zone.public) == 1 && aws_route53_zone.public[0].name == "example.com" && length(aws_iam_role.datasync) == 1 && jsondecode(aws_iam_role.datasync[0].assume_role_policy).Statement[0].Condition.StringEquals["aws:SourceAccount"] == var.config.account_id && jsondecode(aws_iam_role_policy.datasync_images[0].policy).Statement[0].Resource == "arn:aws:s3:::mulo-v3-prod-123456789012-images"
    error_message = "호스티드 존과 동일 계정 images 버킷에만 접근하는 DataSync 역할이 필요합니다."
  }
  assert {
    condition     = !contains(keys(aws_vpc_endpoint.interface), "ecr.api") && !contains(keys(aws_vpc_endpoint.interface), "ecr.dkr") && aws_vpc_endpoint.s3.vpc_endpoint_type == "Gateway" && length(aws_nat_gateway.main) == 3
    error_message = "ECR API·DKR는 NAT로 접근하고 이미지 레이어용 S3 Gateway Endpoint는 유지해야 합니다."
  }
  assert {
    condition     = alltrue([for group in aws_autoscaling_group.worker : length(group.vpc_zone_identifier) == 1]) && length(distinct([for group in values(local.worker_groups) : group.az])) == 3
    error_message = "역할×AZ별 ASG가 하나의 AZ 서브넷만 사용하고 전체 3 AZ에 분산되어야 합니다."
  }

  assert {
    condition     = length(aws_subnet.private) == 3 && length(aws_subnet.data) == 3 && length(aws_nat_gateway.main) == 3
    error_message = "운영은 3 AZ에 독립 NAT와 격리 데이터 서브넷이 있어야 합니다."
  }
  assert {
    condition     = length(aws_instance.control_plane) == 3 && alltrue([for n in aws_instance.control_plane : n.associate_public_ip_address == false])
    error_message = "CP 3대는 공인 IP 없이 생성되어야 합니다."
  }
  assert {
    condition     = aws_lb.api.internal && !aws_lb.web.internal && aws_lb_listener.api.port == 6443 && aws_lb_listener.https.port == 443
    error_message = "클러스터 API와 인터넷 트래픽의 진입점이 분리되어야 합니다."
  }
  assert {
    condition     = one(aws_lb_listener_rule.public.action).type == "forward" && one(one(aws_lb_listener_rule.public.condition).host_header).values == toset(var.config.public_hosts) && one(aws_lb_listener.https.default_action).type == "fixed-response" && one(one(aws_lb_listener.https.default_action).fixed_response).status_code == "403"
    error_message = "공개 앱 호스트만 전달하고 미등록 호스트는 403으로 거부해야 합니다."
  }
  assert {
    condition     = alltrue([for k, rule in merge(local.fixed_rules, local.node_rules) : rule.from == var.config.envoy_node_port ? rule.source == "alb" && rule.target == "api" : true])
    error_message = "Envoy NodePort는 ALB -> api 이외 경로에서 열리면 안 됩니다."
  }
  assert {
    condition     = length(aws_autoscaling_group.worker) == 4 && alltrue([for g in aws_autoscaling_group.worker : g.min_size == 1 && g.desired_capacity == 1 && g.max_size == 1 && g.health_check_type == "EC2"]) && alltrue([for role in keys(var.config.workers) : sum([for key, group in local.worker_groups : group.desired if group.role == role]) == 1])
    error_message = "별도 max 입력 없이 역할별 ASG 1개, min·desired·max 각 1대로 워커 총 4대를 유지해야 합니다."
  }
  assert {
    condition     = alltrue([for g in aws_autoscaling_group.worker : length(g.instance_refresh) == 0])
    error_message = "drain 연동 없이 자동 노드 교체를 활성화하면 안 됩니다."
  }
  assert {
    condition     = length(aws_db_instance.database) == 3 && alltrue([for db in aws_db_instance.database : !db.publicly_accessible && db.storage_encrypted && db.manage_master_user_password && db.multi_az])
    error_message = "RDS 3개는 사설 Multi-AZ, 암호화, 관리형 DB 비밀번호를 사용해야 합니다."
  }
  assert {
    condition     = length(aws_iam_role.pod) == 4 && alltrue([for b in aws_s3_bucket_public_access_block.storage : b.block_public_policy && b.block_public_acls && b.restrict_public_buckets])
    error_message = "Pod IAM 역할 분리와 S3 비공개 설정이 필요합니다."
  }
}
run "development_configuration" {
  command = plan
  variables {
    environment = "dev"
    config = {
      account_id          = "123456789012"
      ami_id              = "ami-0123456789abcdef0"
      vpc_cidr            = "10.80.0.0/16"
      azs                 = ["ap-northeast-2a", "ap-northeast-2b", "ap-northeast-2c"]
      certificate_arn     = "arn:aws:acm:ap-northeast-2:123456789012:certificate/11111111-1111-1111-1111-111111111111"
      public_hosts        = ["dev.example.com"]
      control_plane_count = 1
      single_nat_gateway  = true

      enable_deletion_protection = false
      workers = {
        system = { availability_zones = ["ap-northeast-2a"], instance_type = "m7i.large", min = 1, desired = 1 }
        api    = { availability_zones = ["ap-northeast-2a"], instance_type = "m7i.large", min = 1, desired = 1 }
        chat   = { availability_zones = ["ap-northeast-2a"], instance_type = "m7i.large", min = 1, desired = 1 }
        ai     = { availability_zones = ["ap-northeast-2a"], instance_type = "m7i.xlarge", min = 1, desired = 1 }
      }
    }
  }
  assert {
    condition     = length(aws_instance.control_plane) == 1 && length(aws_nat_gateway.main) == 1 && length(aws_iam_role.pod) == 0 && length(aws_vpn_connection.gcp) == 0 && length(aws_vpn_gateway_route_propagation.migration) == 0 && length(aws_route53_zone.public) == 0 && length(aws_iam_role.datasync) == 0
    error_message = "dev 축소 구성과 미지정 선택 리소스 제외가 동작해야 합니다."
  }
}
run "production_rejects_dev_sizing" {
  command = plan
  variables {
    environment = "prod"
    config = {
      account_id          = "123456789012"
      ami_id              = "ami-0123456789abcdef0"
      vpc_cidr            = "10.80.0.0/16"
      azs                 = ["ap-northeast-2a", "ap-northeast-2b", "ap-northeast-2c"]
      certificate_arn     = "arn:aws:acm:ap-northeast-2:123456789012:certificate/11111111-1111-1111-1111-111111111111"
      public_hosts        = ["dev.example.com"]
      control_plane_count = 1
      single_nat_gateway  = true

      enable_deletion_protection = false
      workers = {
        system = { availability_zones = ["ap-northeast-2a"], instance_type = "m7i.large", min = 1, desired = 1 }
        api    = { availability_zones = ["ap-northeast-2a"], instance_type = "m7i.large", min = 1, desired = 1 }
        chat   = { availability_zones = ["ap-northeast-2a"], instance_type = "m7i.large", min = 1, desired = 1 }
        ai     = { availability_zones = ["ap-northeast-2a"], instance_type = "m7i.xlarge", min = 1, desired = 1 }
      }
    }
  }
  expect_failures = [terraform_data.guardrails]
}
