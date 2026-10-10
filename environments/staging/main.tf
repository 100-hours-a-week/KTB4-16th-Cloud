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
  bootstrap_script  = file("${path.module}/bootstrap.sh")
  startup_scripts   = var.startup_scripts

  use_default_vpc      = false
  enable_cloud_tasks   = true
  ai_vm_count          = 2
  vm_machine_type      = "e2-medium"
  vm_image             = "ubuntu-os-cloud/ubuntu-2204-lts"
  vm_boot_disk_size_gb = 30
  sql_tier             = "db-g1-small"

  sql_deletion_protection = var.sql_deletion_protection
  runtime_enabled         = var.runtime_enabled
}
