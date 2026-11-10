resource "aws_security_group" "role" {
  for_each    = toset(["control-plane", "system", "api", "chat", "ai", "overlay", "api-nlb", "alb", "database", "endpoints"])
  name        = "${local.name}-${each.key}"
  description = "MULO v3 ${each.key} traffic boundary"
  vpc_id      = aws_vpc.main.id
  tags = {
    Name = "${local.name}-${each.key}"
  }
}

# 아웃바운드는 패키지/외부 API용 NAT를 허용합니다. Pod egress 정책은 K8s 구성에서 관리합니다.
resource "aws_vpc_security_group_egress_rule" "outbound" {
  for_each          = toset(["control-plane", "system", "api", "chat", "ai"])
  security_group_id = aws_security_group.role[each.key].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

locals {
  node_roles = toset(["control-plane", "system", "api", "chat", "ai"])
  # 같은 SG를 참조하는 오버레이도 UDP 4789만 허용합니다. NodePort 전체 범위는 열지 않습니다.
  fixed_rules = {
    vxlan = {
      target = "overlay", source = "overlay", protocol = "udp", from = 4789, to = 4789
    }

    api_backend = {
      target = "control-plane", source = "api-nlb", protocol = "tcp", from = 6443, to = 6443
    }

    etcd = {
      target = "control-plane", source = "control-plane", protocol = "tcp", from = 2379, to = 2380
    }

    envoy = {
      target = "api", source = "alb", protocol = "tcp", from = var.config.envoy_node_port, to = var.config.envoy_node_port
    }

  }

  node_rules = merge(
    {
      for role in local.node_roles : "api-${role}" => {
        target = "api-nlb", source = role, protocol = "tcp", from = 6443, to = 6443
      }
    },
    # Kubernetes Service 엔드포인트는 NLB를 우회해 API 서버에 직접 연결됩니다.
    {
      for role in local.node_roles : "direct-api-${role}" => {
        target = "control-plane", source = role, protocol = "tcp", from = 6443, to = 6443
      }
    },
    {
      for role in local.node_roles : "kubelet-${role}" => {
        target = role, source = "control-plane", protocol = "tcp", from = 10250, to = 10250
      }
    },
    {
      for role in local.node_roles : "metrics-kubelet-${role}" => {
        target = role, source = "system", protocol = "tcp", from = 10250, to = 10250
      }
    },
    {
      for role in local.node_roles : "node-exporter-${role}" => {
        target = role, source = "system", protocol = "tcp", from = 9100, to = 9100
      }
    },
    {
      for role in local.node_roles : "endpoint-${role}" => {
        target = "endpoints", source = role, protocol = "tcp", from = 443, to = 443
      }
    },
    {
      for role in ["system", "api", "chat", "ai"] : "mysql-${role}" => {
        target = "database", source = role, protocol = "tcp", from = 3306, to = 3306
      }
    },
    {
      for role in ["system", "api", "ai"] : "postgres-${role}" => {
        target = "database", source = role, protocol = "tcp", from = 5432, to = 5432
      }
    },

  )
}

resource "aws_vpc_security_group_ingress_rule" "internal" {
  for_each                     = merge(local.fixed_rules, local.node_rules)
  security_group_id            = aws_security_group.role[each.value.target].id
  referenced_security_group_id = aws_security_group.role[each.value.source].id
  ip_protocol                  = each.value.protocol
  from_port                    = each.value.from
  to_port                      = each.value.to
  description                  = each.key
}

resource "aws_vpc_security_group_ingress_rule" "public_web" {
  for_each          = toset(["80", "443"])
  security_group_id = aws_security_group.role["alb"].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = tonumber(each.key)
  to_port           = tonumber(each.key)
}

resource "aws_vpc_security_group_egress_rule" "alb" {
  security_group_id            = aws_security_group.role["alb"].id
  referenced_security_group_id = aws_security_group.role["api"].id
  ip_protocol                  = "tcp"
  from_port                    = var.config.envoy_node_port
  to_port                      = var.config.envoy_node_port
}

resource "aws_vpc_security_group_egress_rule" "nlb" {
  security_group_id            = aws_security_group.role["api-nlb"].id
  referenced_security_group_id = aws_security_group.role["control-plane"].id
  ip_protocol                  = "tcp"
  from_port                    = 6443
  to_port                      = 6443
}

