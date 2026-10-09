// 이미지 객체는 비공개로 보관하고, backend VM이 인증 후 조회와 업로드를 처리
resource "google_storage_bucket" "images" {
  name                        = var.image_bucket_name
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  depends_on                  = [google_project_service.required]
}

// backend VM 서비스 계정에 이미지 읽기, 업로드, 삭제 권한을 부여
resource "google_storage_bucket_iam_member" "backend_image_admin" {
  bucket = google_storage_bucket.images.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.vm["backend"].email}"
}
