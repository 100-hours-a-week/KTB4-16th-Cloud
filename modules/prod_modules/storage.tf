// 운영 버킷과 객체는 기존 것을 그대로 사용합니다.
data "google_storage_bucket" "images" {
  name    = var.image_bucket_name
  project = var.project_id
}

// 새 backend VM 서비스 계정에 기존 버킷의 객체 관리 권한만 추가합니다.
resource "google_storage_bucket_iam_member" "backend_image_admin" {
  bucket = data.google_storage_bucket.images.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.vm["backend"].email}"
}
