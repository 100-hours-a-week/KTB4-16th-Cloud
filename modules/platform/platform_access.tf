# 앱용 public_hosts의 ALB 조건 제한과 분리해 운영 도구를 서비스별로 전달합니다.
# 인증서가 있으면 HTTPS, 없으면 기존 HTTP 리스너를 사용합니다.
# 운영 도구는 admin_allowed_cidrs에서 온 요청만 전달하고, 나머지는 리스너 기본 동작(403)으로 떨어집니다.
resource "aws_lb_listener_rule" "platform" {
  for_each     = var.config.platform_services
  listener_arn = local.https_enabled ? aws_lb_listener.https[0].arn : aws_lb_listener.http.arn
  # provider가 빈 우선순위를 할당하도록 두어 서비스 추가 시 기존 규칙을 재정렬하지 않습니다.

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.envoy.arn
  }

  condition {
    host_header {
      values = [each.value.hostname]
    }
  }

  condition {
    source_ip {
      values = var.config.admin_allowed_cidrs
    }
  }
}

# 기존에 이 모듈이 관리하는 공개 존을 사용합니다. DNS 위임은 별도 단계입니다.
# 외부 DNS를 사용하면 platform_access의 dns_target으로 CNAME을 등록합니다.
resource "aws_route53_record" "platform" {
  for_each = var.config.route53_zone == null ? {} : var.config.platform_services
  zone_id  = aws_route53_zone.public[0].zone_id
  name     = each.value.hostname
  type     = "A"

  alias {
    name                   = aws_lb.web.dns_name
    zone_id                = aws_lb.web.zone_id
    evaluate_target_health = true
  }
}

locals {
  platform_scheme = local.https_enabled ? "https" : "http"

  # Terraform은 클러스터에 접속하지 않고 매니페스트만 출력합니다.
  # Route를 대상 Service와 같은 namespace에 생성하므로 ReferenceGrant는 필요하지 않습니다.
  platform_http_routes = join("\n---\n", [
    for name, service in var.config.platform_services : yamlencode({
      apiVersion = "gateway.networking.k8s.io/v1"
      kind       = "HTTPRoute"
      metadata = {
        name      = "${name}-external"
        namespace = service.namespace
      }
      spec = {
        parentRefs = [{
          group       = "gateway.networking.k8s.io"
          kind        = "Gateway"
          name        = var.config.platform_gateway.name
          namespace   = var.config.platform_gateway.namespace
          sectionName = var.config.platform_gateway.listener_name
        }]
        hostnames = [service.hostname]
        rules = [{
          matches = [{ path = { type = "PathPrefix", value = "/" } }]
          backendRefs = [{
            name = service.service_name
            port = service.service_port
          }]
        }]
      }
    })
  ])
}
