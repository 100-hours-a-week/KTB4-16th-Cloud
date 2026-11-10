# 실행: terraform test -var-file=terraform.tfvars.example
mock_provider "aws" {
  mock_data "aws_partition" { defaults = { partition = "aws" } }
  mock_data "aws_ami" { defaults = { architecture = "x86_64", root_device_type = "ebs", root_device_name = "/dev/sda1" } }
}
run "example_inputs" {
  command = plan
  assert {
    condition     = !contains(var.config.interface_endpoints, "ecr.api") && !contains(var.config.interface_endpoints, "ecr.dkr")
    error_message = "환경 입력에 ECR API·DKR 사설 Endpoint를 포함하지 않아야 합니다."
  }
  assert {
    condition     = module.platform.join_parameter_prefix == "/mulo-v3-prod/join/"
    error_message = "환경 접두사가 일치해야 합니다."
  }
  assert {
    condition     = length(module.platform.compute.worker_asgs) == 4 && alltrue([for w in values(var.config.workers) : w.min == 1 && w.desired == 1 && length(w.availability_zones) == 1]) && length(module.platform.endpoints.databases) == 3
    error_message = "현재 구축용 입력은 역할별 1대씩 워커 ASG 4개와 RDS 인스턴스 3개를 생성해야 합니다."
  }
  assert {
    condition     = length(module.platform.migration.vpn_connections) == 2 && length(module.platform.migration.route_propagation_tables) == 4 && module.platform.migration.gcp_app_cidrs == toset(["10.20.0.0/24"]) && module.platform.migration.gcp_database_cidrs == toset(["10.91.0.0/16"]) && module.platform.migration.route53_zone.name == var.config.route53_zone
    error_message = "환경별 GCP 앱·Cloud SQL 대역과 VPN·경로 전파·DNS 예시 입력이 일치해야 합니다."
  }
}
