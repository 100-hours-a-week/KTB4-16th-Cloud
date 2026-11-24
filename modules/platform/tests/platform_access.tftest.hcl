mock_provider "aws" {
  mock_data "aws_partition" { defaults = { partition = "aws" } }
  mock_data "aws_availability_zones" { defaults = { names = ["ap-northeast-2a", "ap-northeast-2b", "ap-northeast-2c"], zone_ids = ["apne2-az1", "apne2-az2", "apne2-az3"] } }
  mock_data "aws_ami" { defaults = { architecture = "x86_64", root_device_type = "ebs", root_device_name = "/dev/sda1" } }
}

variables {
  environment = "prod"
  region      = "ap-northeast-2"
  config = {
    account_id          = "123456789012"
    ami_id              = "ami-0123456789abcdef0"
    vpc_cidr            = "10.60.0.0/16"
    azs                 = ["ap-northeast-2a", "ap-northeast-2b", "ap-northeast-2c"]
    public_hosts        = ["mulo.example.com", "api.example.com", "chat.example.com"]
    route53_zone        = "example.com"
    admin_allowed_cidrs = ["198.51.100.7/32"]
    platform_services = {
      argocd     = { hostname = "argocd.example.com", namespace = "argocd", service_name = "argocd-server", service_port = 80 }
      grafana    = { hostname = "grafana.example.com", namespace = "monitoring", service_name = "grafana", service_port = 80 }
      prometheus = { hostname = "prometheus.example.com", namespace = "monitoring", service_name = "prometheus-kube-prometheus-prometheus", service_port = 9090 }
      loki       = { hostname = "loki.example.com", namespace = "monitoring", service_name = "loki", service_port = 3100 }
    }
    workers = {
      system = { availability_zones = ["ap-northeast-2c"], instance_type = "m7i.large", min = 1, desired = 1 }
      api    = { availability_zones = ["ap-northeast-2a"], instance_type = "m7i.large", min = 1, desired = 1 }
      chat   = { availability_zones = ["ap-northeast-2b"], instance_type = "m7i.large", min = 1, desired = 1 }
      ai     = { availability_zones = ["ap-northeast-2b"], instance_type = "m7i.xlarge", min = 1, desired = 1 }
    }
  }
}

run "http_platform_services" {
  command = plan

  assert {
    condition = length(aws_lb_listener_rule.platform) == 4 && alltrue([
      for name, rule in aws_lb_listener_rule.platform :
      one([for c in rule.condition : c if length(c.host_header) > 0].0.host_header).values == toset([var.config.platform_services[name].hostname]) && one(rule.action).type == "forward"
    ])
    error_message = "앱 도메인 3개와 별도로 운영 도구 4개를 각각 정확한 호스트 조건으로 전달해야 합니다."
  }

  assert {
    condition = alltrue([
      for rule in aws_lb_listener_rule.platform :
      one([for c in rule.condition : c if length(c.source_ip) > 0].0.source_ip).values == toset(["198.51.100.7/32"])
    ])
    error_message = "운영 도구 규칙은 admin_allowed_cidrs에서 온 요청만 전달해야 합니다."
  }
  assert {
    condition     = length(aws_lb_listener.https) == 0 && one(one(aws_lb_listener.http.default_action).fixed_response).status_code == "403" && alltrue([for name, access in output.platform_access : access.url == "http://${var.config.platform_services[name].hostname}"])
    error_message = "인증서가 없으면 HTTP URL을 출력하고 미등록 호스트의 403을 유지해야 합니다."
  }
  assert {
    condition = length(aws_route53_record.platform) == 4 && alltrue([
      for name, record in aws_route53_record.platform :
      record.name == var.config.platform_services[name].hostname && record.type == "A" && one(record.alias).evaluate_target_health
    ])
    error_message = "운영 도구 도메인마다 ALB Alias A 레코드를 생성해야 합니다."
  }
  assert {
    condition = alltrue([
      for route in [for document in split("\n---\n", output.platform_http_routes) : yamldecode(document)] :
      route.apiVersion == "gateway.networking.k8s.io/v1" && route.kind == "HTTPRoute" &&
      route.metadata.namespace == var.config.platform_services[trimsuffix(route.metadata.name, "-external")].namespace &&
      route.spec.hostnames == [var.config.platform_services[trimsuffix(route.metadata.name, "-external")].hostname] &&
      route.spec.parentRefs[0].name == "mulo-gateway" && route.spec.parentRefs[0].namespace == "edge" && route.spec.parentRefs[0].sectionName == "http" &&
      route.spec.rules[0].matches[0].path.type == "PathPrefix" && route.spec.rules[0].matches[0].path.value == "/" &&
      route.spec.rules[0].backendRefs[0].name == var.config.platform_services[trimsuffix(route.metadata.name, "-external")].service_name &&
      route.spec.rules[0].backendRefs[0].port == var.config.platform_services[trimsuffix(route.metadata.name, "-external")].service_port
    ]) && length(split("\n---\n", output.platform_http_routes)) == 4
    error_message = "HTTPRoute는 각 도메인·namespace·Service 포트를 보존하고 공통 Gateway의 HTTP listener에 연결해야 합니다."
  }
}

run "https_platform_services" {
  command = plan
  variables {
    config = merge(var.config, {
      certificate_arn = "arn:aws:acm:ap-northeast-2:123456789012:certificate/11111111-1111-1111-1111-111111111111"
    })
  }
  assert {
    condition     = length(aws_lb_listener.https) == 1 && one(aws_lb_listener.http.default_action).type == "redirect" && length(aws_lb_listener_rule.platform) == 4 && alltrue([for name, access in output.platform_access : access.url == "https://${var.config.platform_services[name].hostname}"])
    error_message = "인증서를 지정하면 운영 도구도 HTTPS URL과 HTTP→HTTPS 리다이렉트를 사용해야 합니다."
  }
}

run "external_dns_and_custom_gateway" {
  command = plan
  variables {
    config = merge(var.config, {
      route53_zone     = null
      platform_gateway = { name = "custom-gateway", namespace = "custom-edge", listener_name = "web" }
    })
  }
  assert {
    condition     = length(aws_route53_record.platform) == 0 && length(aws_lb_listener_rule.platform) == 4 && alltrue([for access in output.platform_access : access.dns_record == null])
    error_message = "외부 DNS를 사용하면 Route 53 레코드 없이 ALB 호스트 규칙을 생성해야 합니다."
  }
  assert {
    condition = alltrue([
      for document in split("\n---\n", output.platform_http_routes) :
      yamldecode(document).spec.parentRefs[0].name == "custom-gateway" &&
      yamldecode(document).spec.parentRefs[0].namespace == "custom-edge" &&
      yamldecode(document).spec.parentRefs[0].sectionName == "web"
    ])
    error_message = "Gateway의 이름·namespace·listener를 환경에 맞게 변경할 수 있어야 합니다."
  }
}

run "platform_services_disabled" {
  command = plan
  variables {
    config = merge(var.config, { platform_services = null })
  }
  assert {
    condition     = length(aws_lb_listener_rule.platform) == 0 && length(aws_route53_record.platform) == 0 && length(output.platform_access) == 0 && output.platform_http_routes == ""
    error_message = "선택 설정을 생략하면 운영 도구 리소스와 매니페스트를 생성하지 않아야 합니다."
  }
}

run "reject_invalid_hostname" {
  command = plan
  variables {
    config = merge(var.config, {
      platform_services = { argocd = merge(var.config.platform_services.argocd, { hostname = "https://argocd.example.com/path" }) }
    })
  }
  expect_failures = [var.config]
}

run "reject_duplicate_hostname" {
  command = plan
  variables {
    config = merge(var.config, {
      platform_services = merge(var.config.platform_services, {
        grafana = merge(var.config.platform_services.grafana, { hostname = "argocd.example.com" })
      })
    })
  }
  expect_failures = [var.config]
}

run "reject_hostname_above_alb_limit" {
  command = plan
  variables {
    config = merge(var.config, {
      platform_services = { argocd = merge(var.config.platform_services.argocd, { hostname = format("%060d.%060d.example.com", 1, 2) }) }
    })
  }
  expect_failures = [var.config]
}

run "reject_app_hostname_overlap" {
  command = plan
  variables {
    config = merge(var.config, {
      platform_services = { argocd = merge(var.config.platform_services.argocd, { hostname = "mulo.example.com" }) }
    })
  }
  expect_failures = [var.config]
}

run "reject_hostname_outside_zone" {
  command = plan
  variables {
    config = merge(var.config, {
      platform_services = { argocd = merge(var.config.platform_services.argocd, { hostname = "argocd.other.com" }) }
    })
  }
  expect_failures = [var.config]
}

run "reject_invalid_service_port" {
  command = plan
  variables {
    config = merge(var.config, {
      platform_services = { argocd = merge(var.config.platform_services.argocd, { service_port = 65536 }) }
    })
  }
  expect_failures = [var.config]
}

run "reject_platform_without_admin_cidrs" {
  command = plan
  variables {
    config = merge(var.config, { admin_allowed_cidrs = [] })
  }
  expect_failures = [var.config]
}

run "reject_open_admin_cidr" {
  command = plan
  variables {
    config = merge(var.config, { admin_allowed_cidrs = ["0.0.0.0/0"] })
  }
  expect_failures = [var.config]
}

run "public_hosts_point_to_alb" {
  command = plan
  assert {
    condition     = length(aws_route53_record.public) == 3 && alltrue([for host, record in aws_route53_record.public : record.name == host && record.type == "A"])
    error_message = "route53_zone이 있으면 앱 도메인도 ALB를 가리키는 A 레코드가 있어야 합니다."
  }
  assert {
    condition     = length(aws_acm_certificate.web) == 0
    error_message = "request_certificate를 켜지 않으면 인증서를 요청하지 않아야 합니다."
  }
}

run "request_certificate" {
  command = plan
  variables {
    config = merge(var.config, { request_certificate = true })
  }
  assert {
    condition     = aws_acm_certificate.web[0].domain_name == "example.com" && aws_acm_certificate.web[0].subject_alternative_names == toset(["*.example.com"]) && aws_acm_certificate.web[0].validation_method == "DNS"
    error_message = "존 이름과 와일드카드를 DNS 검증으로 요청해야 합니다."
  }
}

run "reject_certificate_without_zone" {
  command = plan
  variables {
    config = merge(var.config, { request_certificate = true, route53_zone = null })
  }
  expect_failures = [var.config]
}
