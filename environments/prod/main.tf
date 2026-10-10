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
  bootstrap_script                     = file("${path.module}/bootstrap.sh")

  use_default_vpc      = false
  enable_cloud_tasks   = true
  ai_vm_count          = 2
  vm_machine_type      = var.vm_machine_type
  vm_image             = var.vm_image
  vm_boot_disk_size_gb = 30
  mysql_version        = var.mysql_version
  sql_tier             = var.sql_tier

  sql_deletion_protection = var.sql_deletion_protection
}
