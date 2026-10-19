# 이 폴더의 입력값과 상태를 기준으로 운영 모듈을 적용합니다.
module "mulo" {
  source = "../../modules/prod_modules"

  project_id                           = var.project_id
  domain                               = var.domain
  image_bucket_name                    = var.image_bucket_name
  existing_backend_mysql_instance_name = var.existing_backend_mysql_instance_name
  existing_ai_postgres_instance_name   = var.existing_ai_postgres_instance_name
  name_prefix                          = var.name_prefix
  region                               = var.region
  zone                                 = var.zone
  subnet_cidr                          = var.subnet_cidr
  service_ports                        = var.service_ports
  health_paths                         = var.health_paths
  # 앱과 독립 VM의 스크립트를 분리해 Redis·모니터링의 기존 설치를 유지합니다.
  bootstrap_script              = file("${path.module}/bootstrap.sh")
  base_bootstrap_script         = file("${path.module}/base-bootstrap.sh")
  shutdown_script               = file("${path.module}/shutdown.sh")
  service_image_tags            = var.service_image_tags
  internal_dns_domain           = var.internal_dns_domain
  service_max_rate_per_instance = var.service_max_rate_per_instance

  service_container_images   = var.service_container_images
  redis_vm_machine_type      = var.redis_vm_machine_type
  redis_vm_boot_disk_size_gb = var.redis_vm_boot_disk_size_gb

  use_default_vpc                 = false
  enable_cloud_tasks              = true
  ai_vm_count                     = 2
  vm_machine_type                 = var.vm_machine_type
  vm_image                        = var.vm_image
  vm_boot_disk_size_gb            = 30
  monitoring_vm_machine_type      = var.monitoring_vm_machine_type
  monitoring_vm_boot_disk_size_gb = var.monitoring_vm_boot_disk_size_gb
  monitoring_ports                = var.monitoring_ports
  mysql_version                   = var.mysql_version
  sql_tier                        = var.sql_tier

  sql_deletion_protection = var.sql_deletion_protection
}
