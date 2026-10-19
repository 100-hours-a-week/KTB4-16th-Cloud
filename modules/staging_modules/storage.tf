# 이미지 객체는 비공개로 보관하고 backend가 사용자 권한 확인 후 조회와 업로드를 처리합니다.
# force_destroy=false이므로 객체가 남아 있으면 버킷 삭제를 차단합니다.
resource "google_storage_bucket" "images" {
  name                        = var.image_bucket_name
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  depends_on                  = [google_project_service.required]
}

# backend 서비스 계정에 이미지 객체의 읽기·쓰기·삭제 권한을 부여합니다.
resource "google_storage_bucket_iam_member" "backend_image_admin" {
  bucket = google_storage_bucket.images.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.vm["backend"].email}"
}

# Backend가 키 파일 없이 자신의 계정으로 GCS 서명 URL을 생성합니다.
resource "google_service_account_iam_member" "backend_self_signer" {
  service_account_id = google_service_account.vm["backend"].name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.vm["backend"].email}"
}

# AI도 자신의 서비스 계정에 대한 signBlob 권한을 사용합니다.
resource "google_service_account_iam_member" "ai_self_signer" {
  service_account_id = google_service_account.vm["ai"].name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.vm["ai"].email}"
}
