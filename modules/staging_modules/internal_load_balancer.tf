# backend↔AI는 VM IP 대신 예약된 내부 LB 주소로 통신합니다.
# 외부 HTTP LB와 같은 MIG를 공유하므로 외부는 RATE, 내부는 CONNECTION을 사용합니다.
locals {
  internal_services = toset(["backend", "ai"])
}

resource "google_compute_address" "service_internal" {
  for_each     = local.internal_services
  name         = "${var.name_prefix}-${each.key}-internal-ip"
  region       = var.region
  address_type = "INTERNAL"
  subnetwork   = local.subnetwork_id
}

resource "google_compute_region_backend_service" "internal" {
  for_each                        = local.internal_services
  name                            = "${var.name_prefix}-${each.key}-internal"
  region                          = var.region
  protocol                        = "TCP"
  load_balancing_scheme           = "INTERNAL"
  health_checks                   = [google_compute_health_check.service[each.key].id]
  connection_draining_timeout_sec = 60

  backend {
    group          = google_compute_instance_group_manager.service[each.key].instance_group
    balancing_mode = "CONNECTION"
  }

  # 외부 LB의 RATE 적용이 끝난 뒤 같은 MIG를 내부 LB에 연결합니다.
  depends_on = [google_compute_backend_service.service]
}

resource "google_compute_forwarding_rule" "internal" {
  for_each              = local.internal_services
  name                  = "${var.name_prefix}-${each.key}-internal"
  region                = var.region
  ip_protocol           = "TCP"
  load_balancing_scheme = "INTERNAL"
  backend_service       = google_compute_region_backend_service.internal[each.key].id
  ip_address            = google_compute_address.service_internal[each.key].address
  ports                 = [tostring(var.service_ports[each.key])]
  network               = local.network_id
  subnetwork            = local.subnetwork_id
}

# TCP LB는 클라이언트 IP를 유지하므로 앱 VM 사이에 backend·AI 포트를 허용합니다.
resource "google_compute_firewall" "app_internal" {
  name        = "${var.name_prefix}-allow-app-internal"
  network     = local.network_name
  direction   = "INGRESS"
  source_tags = ["${var.name_prefix}-app"]
  target_tags = ["${var.name_prefix}-app"]

  allow {
    protocol = "tcp"
    ports    = [for service in local.internal_services : tostring(var.service_ports[service])]
  }
}

# private zone의 레코드는 연결한 VPC 안에서만 해석됩니다.
resource "google_dns_managed_zone" "internal" {
  name       = "${var.name_prefix}-internal"
  dns_name   = var.internal_dns_domain
  visibility = "private"

  private_visibility_config {
    networks {
      network_url = local.network_id
    }
  }
  depends_on = [google_project_service.required]
}

resource "google_dns_record_set" "service_internal" {
  for_each     = local.internal_services
  managed_zone = google_dns_managed_zone.internal.name
  name         = "${each.key}.${var.internal_dns_domain}"
  type         = "A"
  ttl          = 60
  rrdatas      = [google_compute_address.service_internal[each.key].address]
}
