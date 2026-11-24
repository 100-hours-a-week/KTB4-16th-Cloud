# 실행: terraform test -var-file=terraform.tfvars.example
mock_provider "aws" {
  mock_data "aws_partition" { defaults = { partition = "aws" } }
  mock_data "aws_availability_zones" { defaults = { names = ["ap-northeast-2a", "ap-northeast-2b", "ap-northeast-2c"], zone_ids = ["apne2-az1", "apne2-az2", "apne2-az3"] } }
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
    condition     = length(module.platform.compute.worker_asgs) == 8 && alltrue([for w in values(var.config.workers) : w.min == 2 && w.desired == 2 && length(w.availability_zones) == 2]) && sum([for w in values(var.config.workers) : w.desired]) == 8 && length(module.platform.endpoints.databases) == 3
    error_message = "현재 구축용 입력은 역할별 2개 AZ에 1대씩(총 8대) 워커 ASG 8개와 RDS 인스턴스 3개를 생성해야 합니다."
  }
  assert {
    # GCP→AWS 이전이 끝나 마이그레이션 VPN(migration_vpn)은 terraform.tfvars에서 뺐다(2026-11-23, AWS에서도 삭제됨).
    condition     = length(module.platform.migration.vpn_connections) == 0 && length(module.platform.migration.route_propagation_tables) == 0
    error_message = "마이그레이션 VPN은 만들지 않아야 합니다."
  }
}
