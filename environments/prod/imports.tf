# 기존 운영 DB를 새로 만들지 않고 이 Terraform 상태에 연결합니다.
import {
  to = module.mulo.google_sql_database_instance.backend_existing
  id = "projects/${var.project_id}/instances/${var.existing_backend_mysql_instance_name}"
}

import {
  to = module.mulo.google_sql_database_instance.ai_existing
  id = "projects/${var.project_id}/instances/${var.existing_ai_postgres_instance_name}"
}

# 콘솔에서 먼저 부여한 Backend 자기 서명 권한을 상태에 등록합니다.
import {
  to = module.mulo.google_service_account_iam_member.backend_self_signer
  id = "projects/${var.project_id}/serviceAccounts/${var.name_prefix}-backend@${var.project_id}.iam.gserviceaccount.com roles/iam.serviceAccountTokenCreator serviceAccount:${var.name_prefix}-backend@${var.project_id}.iam.gserviceaccount.com"
}

# 수동으로 부여한 운영 AI의 자기 서명·사진 읽기 권한을 상태에 등록합니다.
import {
  to = module.mulo.google_service_account_iam_member.ai_self_signer
  id = "projects/${var.project_id}/serviceAccounts/${var.name_prefix}-ai@${var.project_id}.iam.gserviceaccount.com roles/iam.serviceAccountTokenCreator serviceAccount:${var.name_prefix}-ai@${var.project_id}.iam.gserviceaccount.com"
}

import {
  to = module.mulo.google_storage_bucket_iam_member.ai_image_viewer
  id = "b/${var.image_bucket_name} roles/storage.objectViewer serviceAccount:${var.name_prefix}-ai@${var.project_id}.iam.gserviceaccount.com"
}

# 기존 CI 커스텀 역할과 수동 IAM 부여를 가져와 중복 생성을 방지합니다.
import {
  to = google_project_iam_custom_role.ci_healthcheck
  id = "projects/${var.project_id}/roles/ciHealthCheckUser"
}

import {
  to = google_project_iam_member.ci_container_analysis_viewer
  id = "${var.project_id} roles/containeranalysis.occurrences.viewer serviceAccount:github-actions-ci@${var.project_id}.iam.gserviceaccount.com"
}

import {
  to = google_project_iam_member.ci_healthcheck_user
  id = "${var.project_id} projects/${var.project_id}/roles/ciHealthCheckUser serviceAccount:github-actions-ci@${var.project_id}.iam.gserviceaccount.com"
}

# 기존 시크릿의 메타데이터만 가져옵니다. 비밀번호 값·버전은 가져오지 않습니다.
import {
  to = module.mulo.google_secret_manager_secret.be_reader
  id = "projects/${var.project_id}/secrets/${var.name_prefix}-be-reader-password"
}
