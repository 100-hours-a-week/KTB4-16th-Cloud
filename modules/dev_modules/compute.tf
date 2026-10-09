# VM이 다시 만들어져도 개발 접속 주소와 Cloud SQL 허용 IP가 유지됩니다.
resource "google_compute_address" "vm" {
  name         = "${var.name_prefix}-ip"
  region       = var.region
  address_type = "EXTERNAL"
  depends_on   = [google_project_service.required]
}

resource "google_service_account" "vm" {
  account_id   = "${var.name_prefix}-vm"
  display_name = "${var.name_prefix} single development VM"
  depends_on   = [google_project_service.required]
}

# VM에서 Artifact Registry 이미지를 pull하고 Ops Agent가 로그·지표를 전송합니다.
resource "google_project_iam_member" "vm_runtime" {
  for_each = toset([
    "roles/artifactregistry.reader",
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
  ])

  project    = var.project_id
  role       = each.key
  member     = "serviceAccount:${google_service_account.vm.email}"
  depends_on = [google_project_service.required]
}

resource "google_compute_instance" "vm" {
  name                      = "${var.name_prefix}-vm"
  zone                      = var.zone
  machine_type              = var.vm_machine_type
  allow_stopping_for_update = true
  desired_status            = var.runtime_enabled ? "RUNNING" : "TERMINATED"
  tags                      = ["${var.name_prefix}-web"]
  metadata                  = { enable-oslogin = "TRUE" }
  metadata_startup_script   = var.startup_script

  boot_disk {
    initialize_params {
      image = var.vm_image
      size  = var.vm_boot_disk_size_gb
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = data.google_compute_subnetwork.default.id

    access_config {
      nat_ip = google_compute_address.vm.address
    }
  }

  service_account {
    email  = google_service_account.vm.email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  depends_on = [google_project_iam_member.vm_runtime]
}

# Compose의 Nginx와 Certbot이 사용할 HTTP/HTTPS 포트를 엽니다.
resource "google_compute_firewall" "web" {
  name          = "${var.name_prefix}-allow-web"
  network       = data.google_compute_network.default.name
  direction     = "INGRESS"
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["${var.name_prefix}-web"]

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }
}
