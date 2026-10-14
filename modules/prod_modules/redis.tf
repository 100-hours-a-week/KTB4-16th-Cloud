resource "google_service_account" "redis" {
  account_id   = "${var.name_prefix}-redis"
  display_name = "${var.name_prefix} Redis VM"
  depends_on   = [google_project_service.required]
}

resource "google_compute_address" "redis_internal" {
  name         = "${var.name_prefix}-redis-ip"
  region       = var.region
  address_type = "INTERNAL"
  subnetwork   = local.subnetwork_id
}

# Redis는 앱 롤링 배포와 독립적인 단일 VM입니다. 설치와 Compose는 수동 관리합니다.
resource "google_compute_instance" "redis" {
  name                      = "${var.name_prefix}-redis"
  zone                      = var.zone
  machine_type              = var.redis_vm_machine_type
  allow_stopping_for_update = true
  tags                      = ["${var.name_prefix}-redis"]
  labels                    = { service = "redis", environment = "prod" }
  metadata                  = { enable-oslogin = "TRUE" }
  metadata_startup_script   = var.bootstrap_script

  boot_disk {
    # VM 제거 시 디스크는 남깁니다. 교체 VM에 자동 연결되는 것은 아닙니다.
    auto_delete = false
    initialize_params {
      image = var.vm_image
      size  = var.redis_vm_boot_disk_size_gb
      type  = "pd-balanced"
    }
  }
  network_interface {
    subnetwork = local.subnetwork_id
    network_ip = google_compute_address.redis_internal.address
  }
  service_account {
    email  = google_service_account.redis.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }
  depends_on = [google_compute_router_nat.app, google_compute_firewall.redis]
}

# Redis는 공인 IP/LB 없이 앱 VM의 사설 연결만 허용합니다.
resource "google_compute_firewall" "redis" {
  name        = "${var.name_prefix}-allow-redis"
  network     = local.network_name
  direction   = "INGRESS"
  source_tags = ["${var.name_prefix}-app"]
  target_tags = ["${var.name_prefix}-redis"]
  allow {
    protocol = "tcp"
    ports    = ["6379"]
  }
}
