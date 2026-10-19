output "vm_public_ip" {
  value = google_compute_address.vm.address
}

output "vm_private_ip" {
  value = google_compute_address.vm_internal.address
}

output "site_url" {
  value = "https://${var.domain}"
}

output "mysql_public_ip" {
  value = google_sql_database_instance.mysql.public_ip_address
}

output "postgres_public_ip" {
  value = google_sql_database_instance.postgres.public_ip_address
}

output "image_bucket_name" {
  value = google_storage_bucket.images.name
}

output "vm_service_account" {
  value = google_service_account.vm.email
}

output "ai_tasks_queue_id" {
  value = google_cloud_tasks_queue.ai.id
}

output "task_invoker_service_account" {
  value = google_service_account.task_invoker.email
}

# *는 라우팅 패턴입니다. 작업 등록 시에는 앱의 구체적인 처리 경로를 사용합니다.
output "ai_task_target_url" {
  value      = "https://${var.domain}/internal/tasks/*"
  depends_on = [google_cloud_tasks_queue.ai]
}
