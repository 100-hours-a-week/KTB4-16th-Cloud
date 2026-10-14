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
