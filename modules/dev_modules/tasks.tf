# 개발 VM의 backend가 등록하고 AI가 처리할 전용 큐입니다.
resource "google_cloud_tasks_queue" "ai" {
  project  = var.project_id
  name     = "${var.name_prefix}-ai-task"
  location = var.region

  # 단일 개발 VM의 AI 요청이 겹치지 않도록 전달을 제한합니다.
  rate_limits {
    max_dispatches_per_second = 1
    max_concurrent_dispatches = 1
  }

  retry_config {
    max_attempts = 5
    min_backoff  = "5s"
    max_backoff  = "300s"
  }

  depends_on = [google_project_service.required]
}

# HTTP 작업의 OIDC 토큰에 사용할 신원입니다. AI 앱이 토큰을 검증해야 합니다.
resource "google_service_account" "task_invoker" {
  project      = var.project_id
  account_id   = "${var.name_prefix}-task-invoker"
  display_name = "${var.name_prefix} Cloud Tasks OIDC identity"
  depends_on   = [google_project_service.required]
}

# VM 계정의 작업 등록 권한은 개발 큐에만 부여합니다.
resource "google_cloud_tasks_queue_iam_member" "vm_enqueuer" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_tasks_queue.ai.name
  role     = "roles/cloudtasks.enqueuer"
  member   = "serviceAccount:${google_service_account.vm.email}"
}

# backend가 작업 등록 시 위 OIDC 신원을 지정할 수 있게 합니다.
resource "google_service_account_iam_member" "vm_task_invoker_user" {
  service_account_id = google_service_account.task_invoker.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.vm.email}"
}
