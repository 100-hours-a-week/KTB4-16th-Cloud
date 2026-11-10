output "network" {
  value = {
    vpc_id = aws_vpc.main.id
    public_subnet_ids = {
      for az, s in aws_subnet.public : az => s.id
    }

    private_subnet_ids = {
      for az, s in aws_subnet.private : az => s.id
    }

    data_subnet_ids = {
      for az, s in aws_subnet.data : az => s.id
    }

    security_group_ids = {
      for role, sg in aws_security_group.role : role => sg.id
    }
  }
}

output "compute" {
  value = {
    control_planes = {
      for key, node in aws_instance.control_plane : key => {
        id = node.id, ip = node.private_ip, zone = node.availability_zone
      }
    }

    worker_asgs = {
      for role, asg in aws_autoscaling_group.worker : role => asg.name
    }

  }
}

output "endpoints" {
  value = {
    api               = "${aws_lb.api.dns_name}:6443"
    alb_dns           = aws_lb.web.dns_name
    alb_zone_id       = aws_lb.web.zone_id
    envoy_node_port   = var.config.envoy_node_port
    envoy_health_path = var.config.envoy_health_path
    databases = {
      for name, db in aws_db_instance.database : name => {
        endpoint = db.endpoint, master_secret_arn = try(db.master_user_secret[0].secret_arn, null)
      }
    }
  }
}

output "storage" {
  value = {
    buckets = {
      for name, b in aws_s3_bucket.storage : name => b.id
    }

    ecr = {
      for name, r in aws_ecr_repository.app : name => r.repository_url
    }

    vault_kms_key_arn = aws_kms_key.vault.arn
  }
}

output "pod_iam_roles" {
  value = {
    for name, r in aws_iam_role.pod : name => r.arn
  }
}

output "join_parameter_prefix" {
  value = "/${local.name}/join/"
}

# GCP 설정에 전달할 비밀이 아닌 VPN 정보입니다. PSK와 고객 설정 XML은 출력하지 않습니다.
output "migration" {
  value = {
    vpn_gateway_id           = try(aws_vpn_gateway.migration[0].id, null)
    gcp_app_cidrs            = local.gcp_app_cidrs
    gcp_database_cidrs       = local.gcp_db_cidrs
    aws_advertised_cidr      = var.config.vpc_cidr
    route_propagation_tables = keys(local.migration_route_tables)
    aws_bgp_asn              = var.config.migration_vpn == null ? null : var.config.migration_vpn.aws_bgp_asn
    gcp_bgp_asn              = var.config.migration_vpn == null ? null : var.config.migration_vpn.gcp_bgp_asn
    vpn_connections = {
      for name, connection in aws_vpn_connection.gcp : name => {
        connection_id       = connection.id
        customer_gateway_ip = local.migration_peers[name]
        tunnel1 = {
          aws_outside_ip = connection.tunnel1_address
          aws_inside_ip  = connection.tunnel1_vgw_inside_address
          gcp_inside_ip  = connection.tunnel1_cgw_inside_address
          inside_cidr    = connection.tunnel1_inside_cidr
        }
        tunnel2 = {
          aws_outside_ip = connection.tunnel2_address
          aws_inside_ip  = connection.tunnel2_vgw_inside_address
          gcp_inside_ip  = connection.tunnel2_cgw_inside_address
          inside_cidr    = connection.tunnel2_inside_cidr
        }
      }
    }
    route53_zone = {
      id           = try(aws_route53_zone.public[0].zone_id, null)
      name         = var.config.route53_zone
      name_servers = try(aws_route53_zone.public[0].name_servers, [])
    }
    datasync_images_role_arn = try(aws_iam_role.datasync[0].arn, null)
  }
}

