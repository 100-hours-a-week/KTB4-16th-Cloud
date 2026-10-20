# 앱 env에 넣을 고정 주소입니다. VM 교체 후에도 DNS와 LB 주소는 유지됩니다.
output "backend_internal_url" {
  value = "http://${trimsuffix(google_dns_record_set.service_internal["backend"].name, ".")}:${var.service_ports.backend}"
}

output "ai_base_url" {
  value = "http://${trimsuffix(google_dns_record_set.service_internal["ai"].name, ".")}:${var.service_ports.ai}"
}

output "chat_internal_url" {
  value = "http://${trimsuffix(google_dns_record_set.service_internal["chat"].name, ".")}:${var.service_ports.chat}"
}

output "internal_load_balancer_ips" {
  value = { for service, address in google_compute_address.service_internal : service => address.address }
}

output "app_env_secret_names" {
  value = { for service, secret in google_secret_manager_secret.app_env : service => secret.secret_id }
}

output "mig_instance_template_urls" {
  description = "현재 MIG가 참조하는 템플릿입니다. CD 배포 뒤에는 refresh를 포함한 plan/apply로 출력을 갱신합니다."
  value       = { for service, mig in google_compute_instance_group_manager.service : service => mig.version[0].instance_template }
}

output "load_balancer_ip" {
  value = google_compute_global_address.site.address
}

output "site_url" {
  value = "https://${var.domain}"
}

output "mig_names" {
  description = "앱 서비스별 MIG 이름이고, 앱 VM 이름과 IP는 롤링 교체 시 바뀝니다."
  value       = { for key, mig in google_compute_instance_group_manager.service : key => mig.name }
}

output "instance_template_names" {
  description = "Terraform의 기반 템플릿입니다. CD 이후 현재 연결은 mig_instance_template_urls로 확인합니다."
  value       = { for key, template in google_compute_instance_template.service : key => template.name }
}

output "monitoring_instance_group_name" {
  description = "기존 모니터링 VM을 등록한 비관리형 인스턴스 그룹 이름"
  value       = google_compute_instance_group.monitoring.name
}

output "monitoring_urls" {
  description = "DNS 연결과 인증서 발급 완료 후 사용하는 모니터링 HTTPS 주소"
  value       = { for service, config in local.monitoring_services : service => "https://${config.domain}" }
}

output "monitoring_dns_records" {
  description = "외부 DNS에 수동 등록할 모니터링 A 레코드. 환경의 기존 LB IP를 사용합니다."
  value = {
    for service, config in local.monitoring_services : service => {
      name    = config.domain
      type    = "A"
      rrdatas = [google_compute_global_address.site.address]
    }
  }
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

# 라우팅 패턴을 보여주는 출력입니다. 실제 작업에는 * 대신 앱의 구체적인 처리 경로를 사용합니다.
output "ai_task_target_url" {
  value = var.enable_cloud_tasks ? "https://${var.domain}/internal/tasks/*" : null
}
