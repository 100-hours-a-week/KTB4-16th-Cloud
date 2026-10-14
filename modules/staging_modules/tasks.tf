resource "google_cloud_tasks_queue" "ai" {
  count    = var.enable_cloud_tasks ? 1 : 0
  name     = "${var.name_prefix}-ai-task"
  location = var.region

  rate_limits {
    max_dispatches_per_second = 10
    max_concurrent_dispatches = 10
  }

  retry_config {
    max_attempts = 5
    min_backoff  = "5s"
    max_backoff  = "300s"
  }

  depends_on = [google_project_service.required]
}

# API가 HTTP Task를 생성할 때 이 계정으로 OIDC 토큰을 붙이도록 합니다.
resource "google_service_account" "task_invoker" {
  count        = var.enable_cloud_tasks ? 1 : 0
  account_id   = "${var.name_prefix}-task-invoker"
  display_name = "${var.name_prefix} Cloud Tasks OIDC identity"
  depends_on   = [google_project_service.required]
}

# Cloud Tasks Enqueuer와 task-invoker 서비스 계정 사용 권한은 수동으로 부여합니다.
