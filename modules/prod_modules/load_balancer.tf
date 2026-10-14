# LB와 MIG가 함께 참조하는 서비스별 HTTP 헬스체크입니다.
resource "google_compute_health_check" "service" {
  for_each           = local.services
  name               = "${var.name_prefix}-${each.key}-health-checks"
  check_interval_sec = 10
  timeout_sec        = 5

  http_health_check {
    port         = each.value.port
    request_path = each.value.health_path
  }
}

# MIG의 http named port를 사용해 정상 VM에 요청을 분산합니다.
resource "google_compute_backend_service" "service" {
  for_each                        = local.services
  name                            = "${var.name_prefix}-${each.key}-service"
  protocol                        = "HTTP"
  port_name                       = "http"
  load_balancing_scheme           = "EXTERNAL_MANAGED"
  connection_draining_timeout_sec = 300
  # WebSocket 연결과 AI 처리 시간을 고려해 서비스별 요청 제한 시간을 다르게 둡니다.
  timeout_sec   = each.key == "chat" ? 3600 : (each.key == "ai" ? 300 : 30)
  health_checks = [google_compute_health_check.service[each.key].id]

  backend {
    group = google_compute_instance_group_manager.service[each.key].instance_group
    # URL 맵의 경로 분기는 유지합니다. RATE는 서비스 그룹의 목표 용량입니다.
    # 내부 TCP LB(CONNECTION)와 같은 MIG를 공유하도록 backend·AI만 RATE를 사용합니다.
    balancing_mode        = contains(["backend", "ai"], each.key) ? "RATE" : "UTILIZATION"
    max_rate_per_instance = contains(["backend", "ai"], each.key) ? var.service_max_rate_per_instance[each.key] : null
    capacity_scaler       = 1.0
  }

  # 운영 요청 로그를 모두 기록합니다.
  log_config {
    enable      = true
    sample_rate = 1.0
  }
}

# 경로에 맞는 서비스로 전달하며 요청 경로는 변경하지 않습니다.
resource "google_compute_url_map" "https" {
  name            = "${var.name_prefix}-routes"
  default_service = google_compute_backend_service.service["frontend"].id

  host_rule {
    hosts        = [var.domain]
    path_matcher = "mulo"
  }

  # 아래 경로에 해당하지 않는 요청은 frontend로 전달합니다.
  path_matcher {
    name            = "mulo"
    default_service = google_compute_backend_service.service["frontend"].id

    # 이미지 권한 확인과 버킷 접근은 backend가 처리합니다.
    path_rule {
      paths   = ["/image", "/image/*"]
      service = google_compute_backend_service.service["backend"].id
    }

    path_rule {
      paths   = concat(["/ai/*"], var.enable_cloud_tasks ? ["/internal/tasks/*"] : [])
      service = google_compute_backend_service.service["ai"].id
    }

    path_rule {
      paths   = ["/api", "/api/*"]
      service = google_compute_backend_service.service["backend"].id
    }

    path_rule {
      paths   = ["/ws", "/ws/*"]
      service = google_compute_backend_service.service["chat"].id
    }
  }
}

# 도메인의 DNS A 레코드가 LB IP를 가리키면 Google 관리 인증서가 발급됩니다.
resource "google_compute_managed_ssl_certificate" "site" {
  name = "${var.name_prefix}-cert"
  managed {
    domains = [var.domain]
  }
}

# TLS를 종료하고 URL 맵으로 서비스별 라우팅을 수행합니다.
resource "google_compute_target_https_proxy" "site" {
  name             = "${var.name_prefix}-https-proxy"
  url_map          = google_compute_url_map.https.id
  ssl_certificates = [google_compute_managed_ssl_certificate.site.id]
}

# DNS에 등록할 외부 주소입니다. HTTP와 HTTPS가 같은 고정 IP를 사용합니다.
resource "google_compute_global_address" "site" {
  name         = "${var.name_prefix}-lb-ip"
  address_type = "EXTERNAL"
  ip_version   = "IPV4"
}

# 외부 443 요청을 HTTPS 프록시에 전달합니다.
resource "google_compute_global_forwarding_rule" "https" {
  name                  = "${var.name_prefix}-https"
  target                = google_compute_target_https_proxy.site.id
  ip_address            = google_compute_global_address.site.address
  port_range            = "443"
  load_balancing_scheme = "EXTERNAL_MANAGED"
}

# HTTP 요청을 쿼리 문자열을 유지한 채 HTTPS로 리다이렉트합니다.
resource "google_compute_url_map" "http_redirect" {
  name = "${var.name_prefix}-redirect"

  default_url_redirect {
    https_redirect         = true
    strip_query            = false
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
  }
}

# 80 포트는 앱으로 전달하지 않고 HTTPS 리다이렉트에 사용합니다.
resource "google_compute_target_http_proxy" "redirect" {
  name    = "${var.name_prefix}-http-proxy"
  url_map = google_compute_url_map.http_redirect.id
}

resource "google_compute_global_forwarding_rule" "http" {
  name                  = "${var.name_prefix}-http"
  target                = google_compute_target_http_proxy.redirect.id
  ip_address            = google_compute_global_address.site.address
  port_range            = "80"
  load_balancing_scheme = "EXTERNAL_MANAGED"
}
