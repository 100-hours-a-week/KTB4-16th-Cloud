resource "google_sql_database_instance" "mysql" {
  name                = "${var.name_prefix}-mysql"
  region              = var.region
  database_version    = var.mysql_version
  deletion_protection = var.sql_deletion_protection

  settings {
    tier                        = var.sql_tier
    edition                     = "ENTERPRISE"
    availability_type           = "ZONAL"
    disk_type                   = "PD_SSD"
    disk_size                   = 20
    disk_autoresize             = false
    deletion_protection_enabled = var.sql_deletion_protection

    backup_configuration {
      enabled            = false
      binary_log_enabled = false
    }

    activation_policy = var.runtime_enabled ? "ALWAYS" : "NEVER"

    ip_configuration {
      ipv4_enabled = true
      ssl_mode     = "ENCRYPTED_ONLY"

      authorized_networks {
        name  = "dev-vm"
        value = "${google_compute_address.vm.address}/32"
      }
    }
  }

  depends_on = [google_project_service.required]
}

resource "google_sql_database" "mysql" {
  for_each = toset(["mulo", "mulo_chat"])
  name     = each.key
  instance = google_sql_database_instance.mysql.name
}

resource "google_sql_database_instance" "postgres" {
  name                = "${var.name_prefix}-postgres-ai"
  region              = var.region
  database_version    = var.postgres_version
  deletion_protection = var.sql_deletion_protection

  settings {
    tier                        = var.sql_tier
    edition                     = "ENTERPRISE"
    availability_type           = "ZONAL"
    disk_type                   = "PD_SSD"
    disk_size                   = 20
    disk_autoresize             = false
    deletion_protection_enabled = var.sql_deletion_protection

    backup_configuration {
      enabled                        = false
      point_in_time_recovery_enabled = false
    }

    activation_policy = var.runtime_enabled ? "ALWAYS" : "NEVER"

    ip_configuration {
      ipv4_enabled = true
      ssl_mode     = "ENCRYPTED_ONLY"

      authorized_networks {
        name  = "dev-vm"
        value = "${google_compute_address.vm.address}/32"
      }
    }
  }

  depends_on = [google_project_service.required]
}

resource "google_sql_database" "ai" {
  name     = "mulo_ai"
  instance = google_sql_database_instance.postgres.name
}
