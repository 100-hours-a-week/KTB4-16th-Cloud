# 기존 운영 DB를 새로 만들지 않고 이 Terraform 상태에 연결합니다.
import {
  to = module.mulo.google_sql_database_instance.backend_existing
  id = "projects/${var.project_id}/instances/${var.existing_backend_mysql_instance_name}"
}

import {
  to = module.mulo.google_sql_database_instance.ai_existing
  id = "projects/${var.project_id}/instances/${var.existing_ai_postgres_instance_name}"
}
