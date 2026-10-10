output "load_balancer_ip" {
  value = google_compute_global_address.site.address
}

output "site_url" {
  value = "https://${var.domain}"
}

output "vm_private_ips" {
  value = { for key, vm in google_compute_instance.vm : key => vm.network_interface[0].network_ip }
}

output "mysql_private_ips" {
  description = "기존 backend MySQL과 새 chat MySQL의 사설 IP"
  value = {
    be   = data.google_sql_database_instance.backend_private.private_ip_address
    chat = google_sql_database_instance.chat.private_ip_address
  }
}

output "mysql_connection_names" {
  value = {
    be   = google_sql_database_instance.backend_existing.connection_name
    chat = google_sql_database_instance.chat.connection_name
  }
}

output "postgres_connection_name" {
  value = google_sql_database_instance.ai_existing.connection_name
}

output "postgres_private_ip" {
  value = data.google_sql_database_instance.ai_private.private_ip_address
}

output "image_bucket_name" {
  value = data.google_storage_bucket.images.name
}

output "network_name" {
  value = local.network_name
}

output "ai_tasks_queue_id" {
  value = var.enable_cloud_tasks ? google_cloud_tasks_queue.ai[0].id : null
}

output "task_invoker_service_account" {
  value = var.enable_cloud_tasks ? google_service_account.task_invoker[0].email : null
}

output "ai_task_target_url" {
  value = var.enable_cloud_tasks ? "https://${var.domain}/internal/tasks/*" : null
}
