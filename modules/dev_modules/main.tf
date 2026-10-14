locals {
  required_apis = toset([
    "artifactregistry.googleapis.com",
    "compute.googleapis.com",
    "iam.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "sqladmin.googleapis.com",
    "storage.googleapis.com",
  ])
}

# 같은 프로젝트의 다른 환경이 쓰는 API도 있으므로 제거 시 API 자체는 유지합니다.
resource "google_project_service" "required" {
  for_each           = local.required_apis
  service            = each.key
  disable_on_destroy = false
}

# 기존 default VPC와 리전 서브넷을 그대로 사용합니다.
data "google_compute_network" "default" {
  name       = "default"
  project    = var.project_id
  depends_on = [google_project_service.required]
}

data "google_compute_subnetwork" "default" {
  name       = "default"
  region     = var.region
  project    = var.project_id
  depends_on = [google_project_service.required]
}
