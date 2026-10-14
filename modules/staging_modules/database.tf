# backend와 chat의 MySQL을 각각 생성합니다. DB 사용자와 비밀번호는 직접 구성합니다.
resource "google_sql_database_instance" "mysql" {
  for_each         = toset(["be", "chat"])
  name             = "${var.name_prefix}-mysql-${each.key}"
  region           = var.region
  database_version = var.mysql_version
  # Terraform 삭제 보호와 GCP 자체 삭제 보호를 함께 적용합니다.
  deletion_protection = var.sql_deletion_protection

  settings {
    tier                        = var.sql_tier
    edition                     = "ENTERPRISE"
    availability_type           = "ZONAL"
    disk_type                   = "PD_SSD"
    disk_size                   = 20
    disk_autoresize             = false
    deletion_protection_enabled = var.sql_deletion_protection
    # 테스트 환경은 백업과 용량 자동 확장을 끕니다. 데이터 사용량은 별도로 확인합니다.
    backup_configuration {
      enabled            = false
      binary_log_enabled = false
    }

    # 디스크와 DB 정의는 유지하고 실행 상태만 바꿉니다. 앱 MIG 전원은 별도 스크립트로 관리합니다.
    activation_policy = var.runtime_enabled ? "ALWAYS" : "NEVER"

    ip_configuration {
      ipv4_enabled    = false
      private_network = local.network_id
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

# AI용 PostgreSQL도 같은 VPC의 사설 IP로만 연결합니다.
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
