output "network" {
  value = module.platform.network
}

output "compute" {
  value = module.platform.compute
}

output "endpoints" {
  value = module.platform.endpoints
}

output "platform_access" {
  description = "운영 도구 접속 URL과 DNS 연결 대상."
  value       = module.platform.platform_access
}

output "certificate" {
  description = "요청한 ACM 인증서. status가 ISSUED가 되면 arn을 config.certificate_arn에 넣습니다."
  value       = module.platform.certificate
}

output "platform_http_routes" {
  description = "별도로 적용할 Envoy Gateway HTTPRoute YAML."
  value       = module.platform.platform_http_routes
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

output "github_actions_ecr_push_roles" {
  value = module.platform.github_actions_ecr_push_roles
}

output "fis" {
  description = "장애 대응 훈련(FIS) 실험 템플릿 ID와 중단 조건 알람"
  value       = module.platform.fis
}
