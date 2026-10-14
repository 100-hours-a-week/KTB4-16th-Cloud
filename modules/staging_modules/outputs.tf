output "load_balancer_ip" {
  value = google_compute_global_address.site.address
}

output "site_url" {
  value = "https://${var.domain}"
}

output "mig_names" {
  description = "앱 서비스별 MIG 이름. 앱 VM 이름과 IP는 롤링 교체 시 바뀝니다."
  value       = { for key, mig in google_compute_instance_group_manager.service : key => mig.name }
}

output "instance_template_names" {
  value = { for key, template in google_compute_instance_template.service : key => template.name }
}

output "monitoring_vm_name" {
  value = google_compute_instance.monitoring.name
}

output "monitoring_vm_private_ip" {
  value = google_compute_address.monitoring_internal.address
}

output "redis_private_ip" {
  value = google_compute_address.redis_internal.address
}

output "redis_vm_name" {
  value = google_compute_instance.redis.name
}

output "redis_port" {
  value = 6379
}

output "mysql_private_ips" {
  value = { for key, instance in google_sql_database_instance.mysql : key => instance.private_ip_address }
}

output "mysql_connection_names" {
  value = { for key, instance in google_sql_database_instance.mysql : key => instance.connection_name }
}

output "postgres_private_ip" {
  value = google_sql_database_instance.postgres.private_ip_address
}

output "postgres_connection_name" {
  value = google_sql_database_instance.postgres.connection_name
}

output "image_bucket_name" {
  value = google_storage_bucket.images.name
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
