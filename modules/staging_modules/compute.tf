resource "google_service_account" "vm" {
  for_each     = local.services
  account_id   = "${var.name_prefix}-${each.key}"
  display_name = "${var.name_prefix} ${each.key} VM"
  depends_on   = [google_project_service.required]
}

resource "google_compute_instance" "vm" {
  for_each                  = local.vm_instances
  name                      = "${var.name_prefix}-${each.key}"
  zone                      = var.zone
  machine_type              = var.vm_machine_type
  allow_stopping_for_update = true
  desired_status            = var.runtime_enabled ? "RUNNING" : "TERMINATED"
  tags                      = ["${var.name_prefix}-app"]
  metadata                  = { enable-oslogin = "TRUE" }
  metadata_startup_script   = <<-EOT
    #!/bin/bash
    set -euo pipefail
    bash -s <<'MULO_BOOTSTRAP'
    ${var.bootstrap_script}
    MULO_BOOTSTRAP
    ${lookup(var.startup_scripts, each.value, "")}
  EOT

  boot_disk {
    initialize_params {
      image = var.vm_image
      size  = var.vm_boot_disk_size_gb
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = local.subnetwork_id
  }

  service_account {
    email  = google_service_account.vm[each.value].email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  depends_on = [google_compute_router_nat.app]
}

resource "google_compute_instance_group" "service" {
  for_each  = local.services
  name      = "${var.name_prefix}-${each.key}-ig"
  zone      = var.zone
  instances = [for vm_name, service in local.vm_instances : google_compute_instance.vm[vm_name].self_link if service == each.key]
  network   = local.network_id

  named_port {
    name = "http"
    port = each.value.port
  }
}
