resource "google_sql_database_instance" "mysql" {
  for_each            = toset(["be", "chat"])
  name                = "${var.name_prefix}-mysql-${each.key}"
  region              = var.region
  database_version    = var.mysql_version
  deletion_protection = var.sql_deletion_protection // Terraform을 통한 실수로 인한 삭제 보호

  settings {
    tier                        = var.sql_tier
    edition                     = "ENTERPRISE"
    availability_type           = "ZONAL"
    disk_type                   = "PD_SSD"
    disk_size                   = 20
    disk_autoresize             = true
    deletion_protection_enabled = var.sql_deletion_protection
    // GCP 자체 삭제 보호 예를 들면 gcloud, console 삭제 보호

    backup_configuration {
      enabled            = true // 자동 백업
      binary_log_enabled = true // mysql 로그 활성화
    }

    ip_configuration {
      ipv4_enabled    = false            // DB public ip 삭제
      private_network = local.network_id // VPC를 통한 private IP 접속 설정
    }
  }

  depends_on = [google_service_networking_connection.sql]
}

resource "google_sql_database" "mysql" {
  for_each = {
    be   = "mulo"
    chat = "mulo_chat"
  }
  name     = each.value
  instance = google_sql_database_instance.mysql[each.key].name
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
    disk_autoresize             = true
    deletion_protection_enabled = var.sql_deletion_protection

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
    }

    ip_configuration {
      ipv4_enabled    = false
      private_network = local.network_id
    }
  }

  depends_on = [google_service_networking_connection.sql]
}

resource "google_sql_database" "ai" {
  name     = "mulo_ai"
  instance = google_sql_database_instance.postgres.name
}
