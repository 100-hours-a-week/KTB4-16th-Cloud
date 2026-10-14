# 같은 서비스 키로 템플릿·MIG·헬스체크·LB를 연결합니다.
locals {
  services = {
    frontend = { port = var.service_ports.frontend, health_path = var.health_paths.frontend }
    ai       = { port = var.service_ports.ai, health_path = var.health_paths.ai }
    backend  = { port = var.service_ports.backend, health_path = var.health_paths.backend }
    chat     = { port = var.service_ports.chat, health_path = var.health_paths.chat }
  }

  required_apis = toset(concat([
    "compute.googleapis.com",
    "iam.googleapis.com",
    "servicenetworking.googleapis.com",
    "sqladmin.googleapis.com",
    "storage.googleapis.com",
  ], var.enable_cloud_tasks ? ["cloudtasks.googleapis.com"] : []))
}

# 프로젝트 API는 환경 간에 공유하므로 Terraform 리소스를 제거해도 비활성화하지 않습니다.
resource "google_project_service" "required" {
  for_each           = local.required_apis
  service            = each.key
  disable_on_destroy = false
}
