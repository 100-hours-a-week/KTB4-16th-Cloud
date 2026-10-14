output "load_balancer_ip" {
  value = module.mulo.load_balancer_ip
}

output "runtime_enabled" {
  description = "현재 Terraform이 의도한 모니터링·Redis VM과 Cloud SQL 실행 상태. MIG 전원 상태는 별도로 관리합니다."
  value       = var.runtime_enabled
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

output "task_invoker_service_account" {
  value = module.mulo.task_invoker_service_account
}

output "ai_task_target_url" {
  value = module.mulo.ai_task_target_url
}

output "mig_control" {
  description = "mig-power.sh가 사용하는 환경별 프로젝트·존·MIG 이름"
  value = {
    project_id = var.project_id
    zone       = var.zone
    mig_names  = module.mulo.mig_names
  }
}
