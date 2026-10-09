output "load_balancer_ip" {
  value = module.mulo.load_balancer_ip
}

output "site_url" {
  value = module.mulo.site_url
}

output "vm_private_ips" {
  value = module.mulo.vm_private_ips
}

output "mysql_private_ips" {
  value = module.mulo.mysql_private_ips
}

output "mysql_connection_names" {
  value = module.mulo.mysql_connection_names
}

output "postgres_private_ip" {
  value = module.mulo.postgres_private_ip
}

output "postgres_connection_name" {
  value = module.mulo.postgres_connection_name
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
