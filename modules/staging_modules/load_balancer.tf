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

// 로드밸런서가 요청을 전달할 VM 그룹 설정
resource "google_compute_backend_service" "service" {
  for_each              = local.services
  name                  = "${var.name_prefix}-${each.key}-service"
  protocol              = "HTTP"
  port_name             = "http"
  load_balancing_scheme = "EXTERNAL_MANAGED" // 글로벌 외부 Application Load Balancer
  timeout_sec           = each.key == "chat" ? 3600 : (each.key == "ai" ? 300 : 30)
  // chat이면 timeout = 3600, ai는 300, 나머지 30
  health_checks = [google_compute_health_check.service[each.key].id] // 서비스 헬스체크 연결

  backend {
    group           = google_compute_instance_group.service[each.key].self_link
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }

  # 테스트 환경의 로드 밸런서 요청 로그 비용을 줄입니다.
  log_config {
    enable = false
  }

}

// L7 분기 결정
resource "google_compute_url_map" "https" {
  name            = "${var.name_prefix}-routes"
  default_service = google_compute_backend_service.service["frontend"].id

  // domain으로 들어오면 mulo 규칙을 적용하기 위해 설정
  host_rule {
    hosts        = [var.domain]
    path_matcher = "mulo"
  }

  // FE는 도메인은 일치 했지만 아래 경로 규칙은 필요 없다. 따로 설정
  path_matcher {
    name            = "mulo"
    default_service = google_compute_backend_service.service["frontend"].id

    // 이미지 조회와 업로드 요청을 모두 backend VM으로 보냅니다.
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

// GCP TLS 인증서 만들기
resource "google_compute_managed_ssl_certificate" "site" {
  name = "${var.name_prefix}-cert"
  managed {
    domains = [var.domain]
  }
}

// TSL 연결 처리 및 요청 url_amp으로 넘기위한 HTTPS_proxy
resource "google_compute_target_https_proxy" "site" {
  name             = "${var.name_prefix}-https-proxy"
  url_map          = google_compute_url_map.https.id
  ssl_certificates = [google_compute_managed_ssl_certificate.site.id]
}

// 사용자가 접속할 IP 예약
resource "google_compute_global_address" "site" {
  name         = "${var.name_prefix}-lb-ip"
  address_type = "EXTERNAL"
  ip_version   = "IPV4"
}

// HTTPS_proxy 전달 rule
resource "google_compute_global_forwarding_rule" "https" {
  name                  = "${var.name_prefix}-https"
  target                = google_compute_target_https_proxy.site.id
  ip_address            = google_compute_global_address.site.address
  port_range            = "443"
  load_balancing_scheme = "EXTERNAL_MANAGED"
}

// HTTP redirect 설정
resource "google_compute_url_map" "http_redirect" {
  name = "${var.name_prefix}-redirect"

  default_url_redirect {
    https_redirect         = true
    strip_query            = false
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
  }
}

// 위 HTTPS와 동일
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
