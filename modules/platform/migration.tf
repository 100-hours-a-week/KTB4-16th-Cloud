# GCP 쪽 HA VPN/Cloud Router와 PSA 설정은 이 AWS 모듈이 만들지 않습니다.
# 단일 AWS VPC에는 VGW를 사용합니다. CGW는 GCP HA VPN 인터페이스별 1개입니다.
locals {
  migration_peers = var.config.migration_vpn == null ? {} : var.config.migration_vpn.gcp_interface_ips
  gcp_app_cidrs   = var.config.migration_vpn == null ? toset([]) : var.config.migration_vpn.gcp_app_cidrs
  gcp_db_cidrs    = var.config.migration_vpn == null ? toset([]) : var.config.migration_vpn.gcp_database_cidrs
  gcp_cidrs       = setunion(local.gcp_app_cidrs, local.gcp_db_cidrs)

  migration_route_tables = var.config.migration_vpn == null ? {} : merge(
    { for az, rt in aws_route_table.private : "private-${az}" => rt.id },
    { data = aws_route_table.data.id }
  )

  gcp_database_ingress = {
    for entry in flatten([
      for cidr in local.gcp_cidrs : [
        for port in [3306, 5432] : { key = "${cidr}-${port}", cidr = cidr, port = port }
      ]
    ]) : entry.key => entry
  }
  gcp_replication_egress = {
    for entry in flatten([
      for cidr in local.gcp_db_cidrs : [
        for port in [3306, 5432] : { key = "${cidr}-${port}", cidr = cidr, port = port }
      ]
    ]) : entry.key => entry
  }
}

resource "aws_vpn_gateway" "migration" {
  count           = var.config.migration_vpn == null ? 0 : 1
  vpc_id          = aws_vpc.main.id
  amazon_side_asn = var.config.migration_vpn.aws_bgp_asn
  tags = {
    Name = "${local.name}-gcp-migration"
  }
}

resource "aws_customer_gateway" "gcp" {
  for_each   = local.migration_peers
  bgp_asn    = var.config.migration_vpn.gcp_bgp_asn
  ip_address = each.value
  type       = "ipsec.1"
  tags = {
    Name = "${local.name}-gcp-${each.key}"
  }
}

# AWS VPN 연결마다 터널 2개가 제공되므로 HA VPN 인터페이스 2개에 총 4개입니다.
# IKE 제안은 GCP와 동일한 한 가지 조합으로 제한합니다.
resource "aws_vpn_connection" "gcp" {
  for_each            = aws_customer_gateway.gcp
  vpn_gateway_id      = aws_vpn_gateway.migration[0].id
  customer_gateway_id = each.value.id
  type                = "ipsec.1"
  static_routes_only  = false

  tunnel1_ike_versions                 = ["ikev2"]
  tunnel2_ike_versions                 = ["ikev2"]
  tunnel1_phase1_encryption_algorithms = ["AES256"]
  tunnel2_phase1_encryption_algorithms = ["AES256"]
  tunnel1_phase2_encryption_algorithms = ["AES256"]
  tunnel2_phase2_encryption_algorithms = ["AES256"]
  tunnel1_phase1_integrity_algorithms  = ["SHA2-256"]
  tunnel2_phase1_integrity_algorithms  = ["SHA2-256"]
  tunnel1_phase2_integrity_algorithms  = ["SHA2-256"]
  tunnel2_phase2_integrity_algorithms  = ["SHA2-256"]
  tunnel1_phase1_dh_group_numbers      = [14]
  tunnel2_phase1_dh_group_numbers      = [14]
  tunnel1_phase2_dh_group_numbers      = [14]
  tunnel2_phase2_dh_group_numbers      = [14]

  tags = {
    Name = "${local.name}-gcp-${each.key}"
  }
}

# GCP가 BGP로 알린 앱·Cloud SQL 사설 대역을 Private 3개와 Data에 전파합니다.
# 실제 CIDR 경로는 터널/BGP가 성립한 뒤 학습됩니다. Public RT에는 전파하지 않습니다.
resource "aws_vpn_gateway_route_propagation" "migration" {
  for_each       = local.migration_route_tables
  vpn_gateway_id = aws_vpn_gateway.migration[0].id
  route_table_id = each.value
}

resource "aws_vpc_security_group_ingress_rule" "gcp_database" {
  for_each          = local.gcp_database_ingress
  security_group_id = aws_security_group.role["database"].id
  cidr_ipv4         = each.value.cidr
  ip_protocol       = "tcp"
  from_port         = each.value.port
  to_port           = each.value.port
  description       = "GCP migration database access"
}

# 복제는 RDS가 먼저 GCP Cloud SQL에 접속합니다. Data RT의 VPN 경로와 함께 필요합니다.
resource "aws_vpc_security_group_egress_rule" "gcp_replication" {
  for_each          = local.gcp_replication_egress
  security_group_id = aws_security_group.role["database"].id
  cidr_ipv4         = each.value.cidr
  ip_protocol       = "tcp"
  from_port         = each.value.port
  to_port           = each.value.port
  description       = "RDS initiated replication to GCP Cloud SQL"
}

# 노드→GCP는 기존 node outbound 규칙으로 허용합니다.
# GCP→노드 직접 인바운드는 요청 범위에서 제외합니다. 응답 트래픽은 SG가 상태 추적합니다.
