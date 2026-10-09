locals {
  services = {
    frontend = { port = var.service_ports.frontend, health_path = var.health_paths.frontend }
    ai       = { port = var.service_ports.ai, health_path = var.health_paths.ai }
    backend  = { port = var.service_ports.backend, health_path = var.health_paths.backend }
    chat     = { port = var.service_ports.chat, health_path = var.health_paths.chat }
  }

  # 서비스와 VM을 분리합니다. ai-2는 ai 서비스 계정을 공유합니다.
  vm_instances = merge({
    frontend = "frontend"
    ai       = "ai"
    backend  = "backend"
    chat     = "chat"
  }, var.ai_vm_count == 2 ? { "ai-2" = "ai" } : {})

  required_apis = toset(concat([
    "compute.googleapis.com",
    "iam.googleapis.com",
    "servicenetworking.googleapis.com",
    "sqladmin.googleapis.com",
    "storage.googleapis.com",
  ], var.enable_cloud_tasks ? ["cloudtasks.googleapis.com"] : []))
}

resource "google_project_service" "required" {
  for_each           = local.required_apis
  service            = each.key
  disable_on_destroy = false
  // Terraform이 이 API 활성화 리소스를 제거하더라도, GCP API는 비활성화 하지 않는다
}
