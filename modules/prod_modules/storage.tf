# 기존 버킷을 조회만 합니다. 버킷 설정과 객체의 생성·삭제는 Terraform이 관리하지 않습니다.
data "google_storage_bucket" "images" {
  name    = var.image_bucket_name
  project = var.project_id
}

# backend의 객체 권한만 추가하며 버킷의 다른 IAM 구성은 유지합니다.
resource "google_storage_bucket_iam_member" "backend_image_admin" {
  bucket = data.google_storage_bucket.images.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.vm["backend"].email}"
}

# AI가 자신의 계정으로 서명한 URL로 운영 사진을 읽을 수 있습니다.
resource "google_storage_bucket_iam_member" "ai_image_viewer" {
  bucket = data.google_storage_bucket.images.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.vm["ai"].email}"
}

# Backend가 서비스 계정 키 없이 GCS 서명 URL을 만들 때 자신의 계정으로 signBlob을 호출합니다.
resource "google_service_account_iam_member" "backend_self_signer" {
  service_account_id = google_service_account.vm["backend"].name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.vm["backend"].email}"
}

# AI도 키 파일 없이 자신의 계정으로 사진의 서명 URL을 생성합니다.
resource "google_service_account_iam_member" "ai_self_signer" {
  service_account_id = google_service_account.vm["ai"].name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.vm["ai"].email}"
}
