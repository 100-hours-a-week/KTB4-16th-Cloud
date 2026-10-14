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
  labels       = { service = each.key, environment = "staging" }
  # 부팅 스크립트가 이미지 경로·태그와 Secret Manager의 env를 읽어 앱을 실행합니다.
  metadata = merge(
    {
      enable-oslogin  = "TRUE"
      redis-host      = google_compute_address.redis_internal.address
      redis-port      = "6379"
      app-env-secret  = google_secret_manager_secret.app_env[each.key].secret_id
      app-port        = tostring(each.value.port)
      shutdown-script = var.shutdown_script
    },
    lookup(var.service_container_images, each.key, "") != "" ? {
      app-image     = var.service_container_images[each.key]
      app-image-tag = lookup(var.service_image_tags, each.key, "")
    } : {}
  )
  metadata_startup_script = var.bootstrap_script

  disk {
    source_image = var.vm_image
    boot         = true
    # 교체 시 새 디스크를 만들며 부팅 스크립트가 이미지와 env로 앱을 복구합니다.
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
    # 새 템플릿을 먼저 만들어 MIG가 참조 중인 템플릿을 바로 삭제하지 않습니다.
    create_before_destroy = true
    precondition {
      condition     = lookup(var.service_container_images, each.key, "") == "" || lookup(var.service_image_tags, each.key, "") != ""
      error_message = "이미지를 지정한 서비스에는 service_image_tags의 최초 태그도 지정해야 합니다."
    }
  }
  # 새 VM을 만들기 전에 이미지·시크릿 읽기 권한을 부여합니다.
  depends_on = [google_secret_manager_secret_iam_member.vm_env_reader, google_project_iam_member.vm_image_reader]
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
    # 이미지가 없는 chat을 반복 재생성하지 않습니다. 준비된 앱은 HTTP 실패도 복구합니다.
    on_failed_health_check = lookup(var.service_container_images, each.key, "") != "" ? "REPAIR" : "DO_NOTHING"
  }
  # 새 VM 한 대가 정상 상태가 된 뒤 기존 VM을 교체합니다.
  # 새 VM의 부팅·env·이미지 실행이 실패하면 기존 정상 VM을 유지하고 업데이트가 대기합니다.
  update_policy {
    type                  = "PROACTIVE"
    minimal_action        = "REPLACE"
    replacement_method    = "SUBSTITUTE"
    max_surge_fixed       = 1
    max_unavailable_fixed = 0
  }

  # 중지/시작은 MIG stop-instances/start-instances API로 관리합니다.
  # target_size=0 축소 대신 VM과 디스크를 유지한 채 전원을 변경합니다.
  lifecycle {
    # CD의 템플릿 변경과 mig-power.sh의 전원 상태를 모두 유지합니다.
    ignore_changes = [version, target_size, target_stopped_size]
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
  desired_status            = var.runtime_enabled ? "RUNNING" : "TERMINATED"
  tags                      = ["${var.name_prefix}-monitoring"]
  labels                    = { service = "monitoring", environment = "staging" }
  metadata = {
    enable-oslogin = "TRUE"
    startup-script = var.base_bootstrap_script
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
