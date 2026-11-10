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
  name                 = "${local.name}-envoy"
  port                 = var.config.envoy_node_port
  protocol             = "HTTP"
  target_type          = "instance"
  vpc_id               = aws_vpc.main.id
  deregistration_delay = 300
  health_check {
    protocol = "HTTP"
    path     = var.config.envoy_health_path
    port     = "traffic-port"
    matcher  = "200"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.web.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.web.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.config.certificate_arn
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Forbidden"
      status_code  = "403"
    }
  }
}

resource "aws_lb_listener_rule" "public" {
  listener_arn = aws_lb_listener.https.arn
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

