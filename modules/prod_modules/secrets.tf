# env 값과 버전은 직접 등록합니다. Terraform은 서비스별 시크릿 껍데기만 관리합니다.
resource "google_secret_manager_secret" "app_env" {
  for_each  = local.services
  secret_id = "${var.name_prefix}-${each.key}-env"

  replication {
    auto {}
  }

  depends_on = [google_project_service.required]
}

# 수동으로 만든 AI DB 읽기 전용 계정의 시크릿 껍데기만 관리합니다. 값·버전은 직접 등록합니다.
resource "google_secret_manager_secret" "be_reader" {
  secret_id = "${var.name_prefix}-be-reader-password"

  replication {
    auto {}
  }

  depends_on = [google_project_service.required]
}

# 각 서비스는 자기 env만 읽을 수 있습니다.
resource "google_secret_manager_secret_iam_member" "vm_env_reader" {
  for_each  = local.services
  secret_id = google_secret_manager_secret.app_env[each.key].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.vm[each.key].email}"
}

# CD가 지정한 Artifact Registry 이미지를 VM 부팅 시 내려받습니다.
resource "google_project_iam_member" "vm_image_reader" {
  for_each = local.services
  project  = var.project_id
  role     = "roles/artifactregistry.reader"
  member   = "serviceAccount:${google_service_account.vm[each.key].email}"
}
