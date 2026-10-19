output "vm_public_ip" {
  value = module.mulo.vm_public_ip
}

output "vm_private_ip" {
  value = module.mulo.vm_private_ip
}

output "runtime_enabled" {
  description = "현재 Terraform이 의도한 개발 VM과 Cloud SQL 실행 상태"
  value       = var.runtime_enabled
}

output "site_url" {
  value = module.mulo.site_url
}

output "dns_a_record" {
  description = "개발 도메인에 수동으로 설정할 DNS A 레코드"
  value = {
    name    = var.domain
    type    = "A"
    address = module.mulo.vm_public_ip
  }
}

output "mysql_public_ip" {
  value = module.mulo.mysql_public_ip
}

output "postgres_public_ip" {
  value = module.mulo.postgres_public_ip
}

output "image_bucket_name" {
  value = module.mulo.image_bucket_name
}

output "vm_service_account" {
  value = module.mulo.vm_service_account
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
