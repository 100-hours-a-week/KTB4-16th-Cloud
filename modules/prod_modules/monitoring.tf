# 기존 모니터링 VM과 디스크를 유지한 채 외부 LB의 백엔드로 등록합니다.
locals {
  monitoring_services = {
    grafana = {
      domain      = "grafana.${var.domain}"
      port        = var.monitoring_ports.grafana
      health_path = "/api/health"
    }
    prometheus = {
      domain      = "prometheus.${var.domain}"
      port        = var.monitoring_ports.prometheus
      health_path = "/-/ready"
    }
  }
}

# 비관리형 그룹이므로 VM을 재생성하거나 자동 복구하지 않습니다.
resource "google_compute_instance_group" "monitoring" {
  name      = "${var.name_prefix}-monitoring-ig"
  zone      = var.zone
  network   = local.network_id
  instances = [google_compute_instance.monitoring.self_link]

  dynamic "named_port" {
    for_each = local.monitoring_services
    content {
      name = named_port.key
      port = named_port.value.port
    }
  }
}

resource "google_compute_health_check" "monitoring" {
  for_each           = local.monitoring_services
  name               = "${var.name_prefix}-${each.key}-health-checks"
  check_interval_sec = 10
  timeout_sec        = 5

  http_health_check {
    host         = each.value.domain
    port         = each.value.port
    request_path = each.value.health_path
  }
}

# 같은 그룹을 공유하되 서비스별 named port와 헬스체크를 사용합니다.
resource "google_compute_backend_service" "monitoring" {
  for_each                        = local.monitoring_services
  name                            = "${var.name_prefix}-${each.key}-service"
  protocol                        = "HTTP"
  port_name                       = each.key
  load_balancing_scheme           = "EXTERNAL_MANAGED"
  connection_draining_timeout_sec = 300
  # Grafana Live의 WebSocket 연결을 허용합니다.
  timeout_sec   = each.key == "grafana" ? 3600 : 300
  health_checks = [google_compute_health_check.monitoring[each.key].id]

  backend {
    group           = google_compute_instance_group.monitoring.self_link
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }

  log_config {
    enable      = true
    sample_rate = 1.0
  }
}

# Google LB 프록시와 헬스체크에서 Grafana·Prometheus 포트로만 접근합니다.
resource "google_compute_firewall" "monitoring_load_balancer" {
  name          = "${var.name_prefix}-allow-monitoring-lb"
  network       = local.network_name
  direction     = "INGRESS"
  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
  target_tags   = ["${var.name_prefix}-monitoring"]

  allow {
    protocol = "tcp"
    ports    = [for service in local.monitoring_services : tostring(service.port)]
  }
}

# 기존 사이트 인증서는 유지하고 모니터링 도메인용 인증서를 별도로 연결합니다.
resource "google_compute_managed_ssl_certificate" "monitoring" {
  for_each = local.monitoring_services
  name     = "${var.name_prefix}-${each.key}-cert"

  managed {
    domains = [each.value.domain]
  }
}
