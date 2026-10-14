# imports.tf로 등록한 기존 운영 DB를 관리하며, 운영 VPC의 사설 IP와 기존 공인 접속 경로를 함께 유지합니다.
# 기존 DB의 버전·티어는 이 파일에 고정되어 있고, 루트의 sql_tier/mysql_version은 새 chat DB에만 적용됩니다.
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
    # 운영 DB의 삭제·교체를 차단하고, 자동 증가한 용량과 별도로 관리하는 접속 허용 주소는 유지합니다.
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
    # 운영 DB의 삭제·교체를 차단하고, 자동 증가한 용량과 별도로 관리하는 접속 허용 주소는 유지합니다.
    prevent_destroy = true
    ignore_changes = [
      settings[0].disk_size,
      settings[0].ip_configuration[0].authorized_networks,
    ]
  }

  depends_on = [google_service_networking_connection.sql]
}

# 사설 연결 적용이 끝난 뒤 주소를 조회해 출력값과 앱 연결 정보에 사용합니다.
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

# chat은 운영 VPC의 Private Services Access를 사용하는 신규 DB입니다. 사용자와 비밀번호는 직접 구성합니다.
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
