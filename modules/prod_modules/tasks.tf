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

resource "google_cloud_tasks_queue_iam_member" "api_tasks_enqueuer" {
  count    = var.enable_cloud_tasks ? 1 : 0
  project  = var.project_id
  location = var.region
  name     = google_cloud_tasks_queue.ai[0].name
  role     = "roles/cloudtasks.enqueuer"
  member   = "serviceAccount:${google_service_account.vm["backend"].email}"
}

# API가 HTTP Task를 생성할 때 이 계정으로 OIDC 토큰을 붙이도록 합니다.
resource "google_service_account" "task_invoker" {
  count        = var.enable_cloud_tasks ? 1 : 0
  account_id   = "${var.name_prefix}-task-invoker"
  display_name = "${var.name_prefix} Cloud Tasks OIDC identity"
  depends_on   = [google_project_service.required]
}

resource "google_service_account_iam_member" "api_can_act_as_task_invoker" {
  count              = var.enable_cloud_tasks ? 1 : 0
  service_account_id = google_service_account.task_invoker[0].name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.vm["backend"].email}"
}
