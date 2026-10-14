resource "google_service_account" "vm" {
  for_each     = local.services
  account_id   = "${var.name_prefix}-${each.key}"
  display_name = "${var.name_prefix} ${each.key} VM"
  depends_on   = [google_project_service.required]
}

# 앱 VM은 교체할 때 새 내부 IP를 받습니다. 접속은 LB와 서비스 주소를 사용합니다.
resource "google_compute_instance_template" "service" {
  for_each     = local.services
  name_prefix  = "${var.name_prefix}-${each.key}-"
  machine_type = var.vm_machine_type
  region       = var.region
  tags         = ["${var.name_prefix}-app"]
  labels       = { service = each.key, environment = "staging" }
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
    auto_delete  = true
    disk_size_gb = lookup(var.service_vm_boot_disk_sizes_gb, each.key, var.vm_boot_disk_size_gb)
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
    # 롤링 업데이트에서는 상태 검사가 정상인 새 VM을 기다립니다.
    on_failed_health_check = "DO_NOTHING"
  }
  update_policy {
    type                  = "PROACTIVE"
    minimal_action        = "REPLACE"
    replacement_method    = "SUBSTITUTE"
    max_surge_fixed       = 1
    max_unavailable_fixed = 0
  }

  # 중지/시작은 MIG stop-instances/start-instances API로 관리합니다.
  # target_size=0 축소로 수동 설치한 앱 디스크를 삭제하지 않습니다.
  lifecycle {
    ignore_changes = [target_size, target_stopped_size]
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

# 모니터링 전용 독립 VM입니다.
resource "google_compute_instance" "monitoring" {
  name                      = "${var.name_prefix}-monitoring"
  zone                      = var.zone
  machine_type              = var.monitoring_vm_machine_type
  allow_stopping_for_update = true
  desired_status            = var.runtime_enabled ? "RUNNING" : "TERMINATED"
  tags                      = ["${var.name_prefix}-monitoring"]
  labels                    = { service = "monitoring", environment = "staging" }
  metadata = {
    enable-oslogin = "TRUE"
    startup-script = var.bootstrap_script
  }

  boot_disk {
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
