# 개발 VM 한 대와 개발 전용 DB·버킷을 이 폴더의 상태로 관리합니다.
module "mulo" {
  source = "../../modules/dev_modules"

  project_id        = var.project_id
  domain            = var.domain
  image_bucket_name = var.image_bucket_name
  name_prefix       = var.name_prefix
  region            = var.region
  zone              = var.zone
  startup_script    = file("${path.module}/bootstrap.sh")

  vm_machine_type      = "e2-standard-2"
  vm_image             = "ubuntu-os-cloud/ubuntu-2204-lts"
  vm_boot_disk_size_gb = 30
  sql_tier             = "db-g1-small"

  sql_deletion_protection = var.sql_deletion_protection
  runtime_enabled         = var.runtime_enabled
}
