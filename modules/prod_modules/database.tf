# 기존 운영 DB를 import한 뒤 v2 VPC의 사설 IP를 추가합니다.
# 공인 IP는 유지해 기존 VM의 접속 경로를 남깁니다.
resource "google_sql_database_instance" "backend_existing" {
  name                = var.existing_backend_mysql_instance_name
  project             = var.project_id
  region              = var.region
  database_version    = "MYSQL_8_4"
  deletion_protection = true

  settings {
    tier                        = "db-g1-small"
    edition                     = "ENTERPRISE"
    availability_type           = "ZONAL"
    disk_type                   = "PD_SSD"
    disk_size                   = 10
    disk_autoresize             = true
    deletion_protection_enabled = true
    enable_dataplex_integration = true
    retain_backups_on_delete    = true

    final_backup_config {
      enabled        = true
      retention_days = 30
    }

    backup_configuration {
      enabled            = true
      binary_log_enabled = true
      location           = "asia"
      start_time         = "10:00"
    }

    database_flags {
      name  = "default_time_zone"
      value = "+09:00"
    }

    ip_configuration {
      ipv4_enabled    = true
      private_network = local.network_id
      ssl_mode        = "ENCRYPTED_ONLY"
    }

    maintenance_window {
      day          = 1
      hour         = 18
      update_track = "stable"
    }

    password_validation_policy {
      complexity                  = "COMPLEXITY_DEFAULT"
      disallow_username_substring = true
      enable_password_policy      = true
      min_length                  = 8
    }
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes = [
      settings[0].disk_size,
      settings[0].ip_configuration[0].authorized_networks,
    ]
  }

  depends_on = [google_service_networking_connection.sql]
}

resource "google_sql_database_instance" "ai_existing" {
  name                = var.existing_ai_postgres_instance_name
  project             = var.project_id
  region              = var.region
  database_version    = "POSTGRES_18"
  deletion_protection = true

  settings {
    tier                        = "db-g1-small"
    edition                     = "ENTERPRISE"
    availability_type           = "ZONAL"
    disk_type                   = "PD_SSD"
    disk_size                   = 10
    disk_autoresize             = true
    deletion_protection_enabled = true
    enable_dataplex_integration = true
    retain_backups_on_delete    = true

    final_backup_config {
      enabled        = true
      retention_days = 30
    }

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
      location                       = "asia"
      start_time                     = "20:00"
    }

    database_flags {
      name  = "cloudsql.iam_authentication"
      value = "on"
    }

    ip_configuration {
      ipv4_enabled    = true
      private_network = local.network_id
      ssl_mode        = "ENCRYPTED_ONLY"
    }

    maintenance_window {
      day          = 1
      hour         = 18
      update_track = "stable"
    }

    password_validation_policy {
      complexity                  = "COMPLEXITY_DEFAULT"
      disallow_username_substring = true
      enable_password_policy      = true
      min_length                  = 8
    }
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes = [
      settings[0].disk_size,
      settings[0].ip_configuration[0].authorized_networks,
    ]
  }

  depends_on = [google_service_networking_connection.sql]
}

# 사설 IP 추가가 끝난 뒤 실제 할당된 주소를 다시 조회합니다.
data "google_sql_database_instance" "backend_private" {
  name       = var.existing_backend_mysql_instance_name
  project    = var.project_id
  depends_on = [google_sql_database_instance.backend_existing]
}

data "google_sql_database_instance" "ai_private" {
  name       = var.existing_ai_postgres_instance_name
  project    = var.project_id
  depends_on = [google_sql_database_instance.ai_existing]
}

# 아직 없는 채팅 DB만 운영 VPC의 Private Services Access에 새로 생성합니다.
resource "google_sql_database_instance" "chat" {
  name                = "${var.name_prefix}-mysql-chat"
  region              = var.region
  database_version    = var.mysql_version
  deletion_protection = var.sql_deletion_protection

  settings {
    tier                        = var.sql_tier
    edition                     = "ENTERPRISE"
    availability_type           = "ZONAL"
    disk_type                   = "PD_SSD"
    disk_size                   = 20
    disk_autoresize             = true
    deletion_protection_enabled = var.sql_deletion_protection

    backup_configuration {
      enabled            = true
      binary_log_enabled = true
    }

    ip_configuration {
      ipv4_enabled    = false
      private_network = local.network_id
    }
  }

  depends_on = [google_service_networking_connection.sql]
}

resource "google_sql_database" "chat" {
  name     = "mulo_chat"
  instance = google_sql_database_instance.chat.name
}
