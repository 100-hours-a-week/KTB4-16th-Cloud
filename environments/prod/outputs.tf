output "network" {
  value = module.platform.network
}

output "compute" {
  value = module.platform.compute
}

output "endpoints" {
  value = module.platform.endpoints
}

output "storage" {
  value = module.platform.storage
}

output "pod_iam_roles" {
  value = module.platform.pod_iam_roles
}

output "join_parameter_prefix" {
  value = module.platform.join_parameter_prefix
}


output "migration" {
  value = module.platform.migration
}
