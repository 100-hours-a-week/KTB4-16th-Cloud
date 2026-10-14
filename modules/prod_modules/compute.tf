resource "google_service_account" "vm" {
  for_each     = local.services
  account_id   = "${var.name_prefix}-${each.key}"
  display_name = "${var.name_prefix} ${each.key} VM"
  depends_on   = [google_project_service.required]
}

# 템플릿은 VM 생성 설정입니다. 실행 중인 VM의 Compose 파일이나 디스크 변경은 저장하지 않습니다.
# 앱 VM의 내부 IP는 자동 할당되며, 교체 후에는 서비스 탐색이나 LB를 통해 접근합니다.
resource "google_compute_instance_template" "service" {
  for_each     = local.services
  name_prefix  = "${var.name_prefix}-${each.key}-"
  machine_type = var.vm_machine_type
  region       = var.region
  tags         = ["${var.name_prefix}-app"]
  labels       = { service = each.key, environment = "prod" }
  # app-image는 배포 시 참고할 주소이며, 이미지를 내려받거나 앱을 실행하지 않습니다.
  metadata = merge(
    {
      enable-oslogin = "TRUE"
      redis-host     = google_compute_address.redis_internal.address
      redis-port     = "6379"
    },
    lookup(var.service_container_images, each.key, "") != "" ? { app-image = var.service_container_images[each.key] } : {}
  )
  metadata_startup_script = var.bootstrap_script

  disk {
    source_image = var.vm_image
    boot         = true
    # 교체 시 새 디스크를 만듭니다. 앱 설정을 복구하려면 이미지나 별도 배포 구성이 필요합니다.
    auto_delete  = true
    disk_size_gb = var.vm_boot_disk_size_gb
    disk_type    = "pd-balanced"
  }

  network_interface {
    subnetwork = local.subnetwork_id
  }

  service_account {
    email  = google_service_account.vm[each.key].email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  lifecycle {
    # 새 템플릿을 먼저 만들어 MIG가 참조 중인 템플릿을 바로 삭제하지 않습니다.
    create_before_destroy = true
  }
}

resource "google_compute_instance_group_manager" "service" {
  for_each           = local.services
  name               = "${var.name_prefix}-${each.key}-mig"
  base_instance_name = "${var.name_prefix}-${each.key}"
  zone               = var.zone
  target_size        = each.key == "ai" ? var.ai_vm_count : 1

  version {
    instance_template = google_compute_instance_template.service[each.key].self_link_unique
  }
  named_port {
    name = "http"
    port = each.value.port
  }
  auto_healing_policies {
    health_check      = google_compute_health_check.service[each.key].id
    initial_delay_sec = 600
  }
  instance_lifecycle_policy {
    # 앱은 수동 설치하므로 HTTP 실패로 VM을 자동 재생성하지 않습니다.
    # VM 자체 장애 복구와 롤링 업데이트의 헬스체크는 별도로 동작합니다.
    on_failed_health_check = "DO_NOTHING"
  }
  # 새 VM 한 대가 정상 상태가 된 뒤 기존 VM을 교체합니다.
  # 새 VM에 앱을 배포하지 않으면 헬스체크 확인 단계에서 업데이트가 대기할 수 있습니다.
  update_policy {
    type                  = "PROACTIVE"
    minimal_action        = "REPLACE"
    replacement_method    = "SUBSTITUTE"
    max_surge_fixed       = 1
    max_unavailable_fixed = 0
  }

  depends_on = [google_compute_router_nat.app, google_compute_firewall.load_balancer]
}

resource "google_service_account" "monitoring" {
  account_id   = "${var.name_prefix}-monitoring"
  display_name = "${var.name_prefix} monitoring VM"
  depends_on   = [google_project_service.required]
}

resource "google_project_iam_member" "monitoring_ops_agent" {
  for_each = toset(["roles/logging.logWriter", "roles/monitoring.metricWriter"])

  project = var.project_id
  role    = each.key
  member  = "serviceAccount:${google_service_account.monitoring.email}"
}

resource "google_compute_address" "monitoring_internal" {
  name         = "${var.name_prefix}-monitoring-ip"
  region       = var.region
  address_type = "INTERNAL"
  subnetwork   = local.subnetwork_id
}

# 모니터링은 MIG 교체 대상에서 제외하고 예약된 내부 IP로 접근합니다.
resource "google_compute_instance" "monitoring" {
  name                      = "${var.name_prefix}-monitoring"
  zone                      = var.zone
  machine_type              = var.monitoring_vm_machine_type
  allow_stopping_for_update = true
  tags                      = ["${var.name_prefix}-monitoring"]
  labels                    = { service = "monitoring", environment = "prod" }
  metadata = {
    enable-oslogin = "TRUE"
    startup-script = var.bootstrap_script
  }

  boot_disk {
    # VM 삭제 후 디스크는 남지만, 새 VM에 자동으로 다시 연결되지는 않습니다.
    auto_delete = false
    device_name = "monitoring-boot"
    initialize_params {
      image = var.vm_image
      size  = var.monitoring_vm_boot_disk_size_gb
      type  = "pd-balanced"
    }
  }
  network_interface {
    subnetwork = local.subnetwork_id
    network_ip = google_compute_address.monitoring_internal.address
  }
  service_account {
    email  = google_service_account.monitoring.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  depends_on = [google_compute_router_nat.app, google_project_iam_member.monitoring_ops_agent]
}
