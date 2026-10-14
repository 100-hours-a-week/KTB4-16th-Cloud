# 큐는 전달 속도와 재시도를 제어합니다. 실제 HTTP 작업 등록은 backend 앱이 담당합니다.
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

# HTTP 작업의 OIDC 토큰에 사용할 신원입니다. 이 계정을 만드는 것만으로 작업 권한이 부여되지는 않습니다.
resource "google_service_account" "task_invoker" {
  count        = var.enable_cloud_tasks ? 1 : 0
  account_id   = "${var.name_prefix}-task-invoker"
  display_name = "${var.name_prefix} Cloud Tasks OIDC identity"
  depends_on   = [google_project_service.required]
}

# 작업 등록·서비스 계정 사용 권한과 AI 앱의 토큰 검증은 직접 구성합니다.
