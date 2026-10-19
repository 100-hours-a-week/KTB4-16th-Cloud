# 비공개 이미지 버킷입니다. 객체가 남아 있으면 Terraform에서 버킷을 삭제할 수 없습니다.
resource "google_storage_bucket" "images" {
  name                        = var.image_bucket_name
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  depends_on                  = [google_project_service.required]
}

resource "google_storage_bucket_iam_member" "vm_images" {
  bucket = google_storage_bucket.images.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.vm.email}"
}

# 개발 VM이 키 파일 없이 자신의 계정으로 GCS 서명 URL을 생성합니다.
resource "google_service_account_iam_member" "vm_self_signer" {
  service_account_id = google_service_account.vm.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.vm.email}"
}
