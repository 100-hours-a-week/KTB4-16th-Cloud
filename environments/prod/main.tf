module "platform" {
  source      = "../../modules/platform"
  environment = "prod"
  region      = var.region
  config      = var.config
}

