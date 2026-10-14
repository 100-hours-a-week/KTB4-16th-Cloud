# 스테이징 리소스와 상태는 운영 환경과 별도로 관리합니다.
module "mulo" {
  source = "../../modules/staging_modules"

  project_id        = var.project_id
  domain            = var.domain
  image_bucket_name = var.image_bucket_name
  name_prefix       = var.name_prefix
  region            = var.region
  zone              = var.zone
  subnet_cidr       = var.subnet_cidr
  service_ports     = var.service_ports
  health_paths      = var.health_paths
  # 스크립트 내용 변경도 앱 템플릿 변경과 롤링 교체를 유발할 수 있습니다.
  bootstrap_script = file("${path.module}/bootstrap.sh")

  service_container_images      = var.service_container_images
  service_vm_boot_disk_sizes_gb = var.service_vm_boot_disk_sizes_gb
  redis_vm_machine_type         = var.redis_vm_machine_type
  redis_vm_boot_disk_size_gb    = var.redis_vm_boot_disk_size_gb

  use_default_vpc                 = false
  enable_cloud_tasks              = true
  ai_vm_count                     = 2
  vm_machine_type                 = "e2-medium"
  vm_image                        = "ubuntu-os-cloud/ubuntu-2204-lts"
  vm_boot_disk_size_gb            = 30
  monitoring_vm_machine_type      = var.monitoring_vm_machine_type
  monitoring_vm_boot_disk_size_gb = var.monitoring_vm_boot_disk_size_gb
  sql_tier                        = "db-g1-small"

  sql_deletion_protection = var.sql_deletion_protection
  runtime_enabled         = var.runtime_enabled
}
