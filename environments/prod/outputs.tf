output "backend_internal_url" {
  value = module.mulo.backend_internal_url
}

output "ai_base_url" {
  value = module.mulo.ai_base_url
}

output "chat_internal_url" {
  value = module.mulo.chat_internal_url
}

output "internal_load_balancer_ips" {
  value = module.mulo.internal_load_balancer_ips
}

output "app_env_secret_names" {
  value = module.mulo.app_env_secret_names
}

output "mig_instance_template_urls" {
  value = module.mulo.mig_instance_template_urls
}

output "load_balancer_ip" {
  value = module.mulo.load_balancer_ip
}

output "site_url" {
  value = module.mulo.site_url
}

output "mig_names" {
  value = module.mulo.mig_names
}

output "instance_template_names" {
  value = module.mulo.instance_template_names
}

output "monitoring_instance_group_name" {
  value = module.mulo.monitoring_instance_group_name
}

output "monitoring_urls" {
  value = module.mulo.monitoring_urls
}

output "monitoring_dns_records" {
  value = module.mulo.monitoring_dns_records
}

output "monitoring_vm_name" {
  value = module.mulo.monitoring_vm_name
}

output "monitoring_vm_private_ip" {
  value = module.mulo.monitoring_vm_private_ip
}

output "redis_private_ip" {
  value = module.mulo.redis_private_ip
}

output "redis_vm_name" {
  value = module.mulo.redis_vm_name
}

output "redis_port" {
  value = module.mulo.redis_port
}

output "mysql_private_ips" {
  value = module.mulo.mysql_private_ips
}

output "mysql_connection_names" {
  value = module.mulo.mysql_connection_names
}

output "postgres_connection_name" {
  value = module.mulo.postgres_connection_name
}

output "postgres_private_ip" {
  value = module.mulo.postgres_private_ip
}

output "image_bucket_name" {
  value = module.mulo.image_bucket_name
}

output "network_name" {
  value = module.mulo.network_name
}

output "ai_tasks_queue_id" {
  value = module.mulo.ai_tasks_queue_id
}

output "ai_tasks_queue_name" {
  description = "기존 루트 출력 이름과의 호환용입니다. 값은 큐의 ID입니다."
  value       = module.mulo.ai_tasks_queue_id
}

output "task_invoker_service_account" {
  value = module.mulo.task_invoker_service_account
}

output "ai_task_target_url" {
  value = module.mulo.ai_task_target_url
}
