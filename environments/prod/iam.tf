# 프로젝트 공용 CI 권한은 prod 상태에서만 관리합니다.
locals {
  ci_service_account_member = "serviceAccount:github-actions-ci@${var.project_id}.iam.gserviceaccount.com"
}

# 이미지 존재 확인 명령이 함께 조회하는 취약점 정보에 대한 읽기 권한입니다.
resource "google_project_iam_member" "ci_container_analysis_viewer" {
  project = var.project_id
  role    = "roles/containeranalysis.occurrences.viewer"
  member  = local.ci_service_account_member
}

# MIG 롤링 업데이트 시 기존 헬스체크를 사용할 최소 권한입니다.
resource "google_project_iam_custom_role" "ci_healthcheck" {
  project     = var.project_id
  role_id     = "ciHealthCheckUser"
  title       = "CI health check user"
  description = "CD가 MIG 롤링 업데이트 때 헬스체크를 사용"
  permissions = [
    "compute.healthChecks.use",
    "compute.healthChecks.useReadOnly",
  ]
}

resource "google_project_iam_member" "ci_healthcheck_user" {
  project = var.project_id
  role    = google_project_iam_custom_role.ci_healthcheck.name
  member  = local.ci_service_account_member
}
