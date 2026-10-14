# backend와 chat의 DB를 한 MySQL 인스턴스에 생성합니다. 사용자·비밀번호는 직접 구성합니다.
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

    # 데이터와 디스크를 유지한 채 인스턴스만 중지하거나 시작합니다.
    activation_policy = var.runtime_enabled ? "ALWAYS" : "NEVER"

    # 개발 VM의 예약 공인 IP에서만 TLS 연결을 허용합니다.
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

# 개발 AI DB 이름은 muro_ai이며, 스테이징의 mulo_ai와 철자가 다릅니다.
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
  name     = "muro_ai"
  instance = google_sql_database_instance.postgres.name
}
