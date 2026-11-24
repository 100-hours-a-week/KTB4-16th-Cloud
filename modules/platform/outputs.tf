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

output "platform_access" {
  description = "운영 도구 접속 URL과 DNS 연결 대상. DNS 위임 및 Kubernetes 라우트 적용 후 접속할 수 있습니다."
  value = {
    for name, service in var.config.platform_services : name => {
      url        = "${local.platform_scheme}://${service.hostname}"
      hostname   = service.hostname
      dns_target = aws_lb.web.dns_name
      dns_record = try(aws_route53_record.platform[name].fqdn, null)
    }
  }
}

output "certificate" {
  description = "요청한 ACM 인증서. status가 ISSUED가 되면 arn을 config.certificate_arn에 넣습니다."
  # 리소스가 실제로 있을 때만 읽습니다. 설정만 켜고 아직 만들지 않은 상태(refresh, destroy)에서도 오류가 나지 않습니다.
  value = length(aws_acm_certificate.web) == 0 ? null : {
    arn    = aws_acm_certificate.web[0].arn
    status = aws_acm_certificate.web[0].status
  }
}

output "platform_http_routes" {
  description = "Envoy Gateway용 HTTPRoute YAML. 별도로 검토한 뒤 kubectl apply -f로 적용하세요."
  value       = local.platform_http_routes
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


output "github_actions_ecr_push_roles" {
  description = "GitHub Actions가 aws-actions/configure-aws-credentials의 role-to-assume으로 쓰는 ECR push 역할 ARN."
  value = {
    for name, r in aws_iam_role.github_ecr_push : name => r.arn
  }
}

output "fis" {
  description = "장애 대응 훈련(FIS) 실험 템플릿 ID와 중단 조건 알람"
  value = {
    az_outage    = { for az, t in aws_fis_experiment_template.az_outage : az => t.id }
    stop_general = { for az, t in aws_fis_experiment_template.stop_general : az => t.id }
    stop_alarm   = aws_cloudwatch_metric_alarm.fis_stop.alarm_name
    log_group    = aws_cloudwatch_log_group.fis.name
  }
}
