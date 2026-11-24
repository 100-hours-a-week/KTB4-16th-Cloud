resource "aws_lb" "api" {
  name                             = "${local.name}-api"
  internal                         = true
  load_balancer_type               = "network"
  subnets                          = [for az in var.config.azs : aws_subnet.private[az].id]
  security_groups                  = [aws_security_group.role["api-nlb"].id]
  enable_cross_zone_load_balancing = true
  enable_deletion_protection       = var.config.enable_deletion_protection
}

resource "aws_lb_target_group" "api" {
  name        = "${local.name}-api"
  port        = 6443
  protocol    = "TCP"
  target_type = "instance"
  vpc_id      = aws_vpc.main.id
  # NLB -> 같은 노드로 돌아오는 제어면 트래픽의 hairpin 문제를 피합니다.
  preserve_client_ip = false
  health_check {
    protocol = "TCP"
    port     = "traffic-port"
  }
}

resource "aws_lb_target_group_attachment" "api" {
  for_each         = aws_instance.control_plane
  target_group_arn = aws_lb_target_group.api.arn
  target_id        = each.value.id
  port             = 6443
}

resource "aws_lb_listener" "api" {
  load_balancer_arn = aws_lb.api.arn
  port              = 6443
  protocol          = "TCP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

resource "aws_lb" "web" {
  name                       = "${local.name}-web"
  internal                   = false
  load_balancer_type         = "application"
  subnets                    = [for az in var.config.azs : aws_subnet.public[az].id]
  security_groups            = [aws_security_group.role["alb"].id]
  enable_deletion_protection = var.config.enable_deletion_protection
  drop_invalid_header_fields = true
  idle_timeout               = 300
}

resource "aws_lb_target_group" "envoy" {
  name        = "${local.name}-envoy"
  port        = var.config.envoy_node_port
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = aws_vpc.main.id
  # AZ 장애 때 죽은 대상을 빨리 빼도록 감지를 짧게 합니다(2026-11-24 2c 훈련: 30초×3회로는 최대 90초 동안 요청 절반이 멈춤).
  # 연결을 끊기 전 기다리는 시간도 300초에서 30초로 줄입니다. Envoy 요청은 대부분 수 초 안에 끝납니다.
  deregistration_delay = 30
  health_check {
    protocol            = "HTTP"
    path                = var.config.envoy_health_path
    port                = "traffic-port"
    matcher             = "200"
    interval            = 10 # 기존 30
    timeout             = 5  # 기존 5(유지). interval보다 짧아야 합니다
    unhealthy_threshold = 2  # 기존 3. 10초×2회 = 약 20초 안에 제외
    healthy_threshold   = 2  # 기존 3. 복구도 약 20초 안에 다시 넣음
  }
}

locals {
  https_enabled = var.config.certificate_arn != null
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.web.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type = local.https_enabled ? "redirect" : "fixed-response"
    dynamic "redirect" {
      for_each = local.https_enabled ? [1] : []
      content {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
    dynamic "fixed_response" {
      for_each = local.https_enabled ? [] : [1]
      content {
        content_type = "text/plain"
        message_body = "Forbidden"
        status_code  = "403"
      }
    }
  }
}

resource "aws_lb_listener" "https" {
  count             = local.https_enabled ? 1 : 0
  load_balancer_arn = aws_lb.web.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.config.certificate_arn
  # ALB가 공개 입구가 되므로 GCP와 같은 HSTS 헤더를 붙입니다. 전환 안정화 뒤 max-age를 늘립니다.
  routing_http_response_strict_transport_security_header_value = var.config.hsts_header_value
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Forbidden"
      status_code  = "403"
    }
  }
}

moved {
  from = aws_lb_listener.https
  to   = aws_lb_listener.https[0]
}

resource "aws_lb_listener_rule" "public" {
  listener_arn = local.https_enabled ? aws_lb_listener.https[0].arn : aws_lb_listener.http.arn
  priority     = 30
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.envoy.arn
  }

  condition {
    host_header {
      values = var.config.public_hosts
    }
  }
}

resource "aws_wafv2_web_acl" "web" {
  name  = "${local.name}-web"
  scope = "REGIONAL"
  default_action {
    allow {
    }
  }

  # 같은 IP의 요청 폭주(회원가입 API 등)를 5분 단위 요청 수로 차단합니다. waf_rate_limit이 null이면 만들지 않습니다.
  dynamic "rule" {
    for_each = var.config.waf_rate_limit == null ? [] : [var.config.waf_rate_limit]
    content {
      name     = "rate-limit-per-ip"
      priority = 0
      action {
        block {
        }
      }

      statement {
        rate_based_statement {
          limit                 = rule.value
          evaluation_window_sec = 300
          aggregate_key_type    = "IP"
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${local.name}-rate-limit"
        sampled_requests_enabled   = true
      }
    }
  }

  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1
    override_action {
      none {
      }
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"

        # 이 규칙은 8KB를 넘는 요청 본문을 막아 /image 업로드와 큰 JSON 요청이 403이 됩니다.
        # 차단하지 않고 지표로만 남깁니다.
        rule_action_override {
          name = "SizeRestrictions_BODY"
          action_to_use {
            count {
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name}-common"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name}-waf"
    sampled_requests_enabled   = true
  }
}

resource "aws_wafv2_web_acl_association" "web" {
  resource_arn = aws_lb.web.arn
  web_acl_arn  = aws_wafv2_web_acl.web.arn
}
