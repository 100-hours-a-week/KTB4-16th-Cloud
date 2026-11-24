# 실제 AWS를 호출하지 않고 워커 AMI·상한·가입 템플릿의 연결을 검증합니다.
mock_provider "aws" {
  mock_data "aws_partition" { defaults = { partition = "aws" } }
  mock_data "aws_availability_zones" { defaults = { names = ["ap-northeast-2a", "ap-northeast-2b", "ap-northeast-2c"], zone_ids = ["apne2-az1", "apne2-az2", "apne2-az3"] } }
  mock_data "aws_ami" {
    defaults = {
      id               = "ami-0fedcba9876543210"
      architecture     = "x86_64"
      root_device_type = "ebs"
      root_device_name = "/dev/xvda"
    }
  }
}

# 워커 이미지를 바꿔도 CP는 기존 이미지를 사용해야 합니다.
override_data {
  target = data.aws_ami.node
  values = {
    id               = "ami-0123456789abcdef0"
    architecture     = "x86_64"
    root_device_type = "ebs"
    root_device_name = "/dev/sda1"
  }
}

variables {
  environment = "prod"
  region      = "ap-northeast-2"
  config = {
    account_id   = "123456789012"
    ami_id       = "ami-0123456789abcdef0"
    vpc_cidr     = "10.60.0.0/16"
    azs          = ["ap-northeast-2a", "ap-northeast-2b", "ap-northeast-2c"]
    public_hosts = ["mulo.example.com"]
    workers = {
      api    = { availability_zones = ["ap-northeast-2a"], instance_type = "m7i.large", ami_id = "ami-0fedcba9876543210", min = 1, desired = 1, max = 3 }
      ai     = { availability_zones = ["ap-northeast-2b"], instance_type = "m7i.xlarge", ami_id = "ami-0fedcba9876543210", min = 1, desired = 1, max = 3 }
      chat   = { availability_zones = ["ap-northeast-2b"], instance_type = "m7i.large", ami_id = "ami-0fedcba9876543210", min = 1, desired = 1, max = 2 }
      system = { availability_zones = ["ap-northeast-2c"], instance_type = "m7i.large", ami_id = "ami-0fedcba9876543210", min = 1, desired = 1, max = 2 }
    }
  }
}

run "worker_image_limits_and_join" {
  command = plan

  assert {
    condition     = alltrue([for cp in aws_instance.control_plane : cp.ami == "ami-0123456789abcdef0"]) && alltrue([for lt in aws_launch_template.worker : lt.image_id == "ami-0fedcba9876543210"])
    error_message = "워커 전용 AMI를 지정해도 CP의 기존 AMI는 유지해야 합니다."
  }
  assert {
    condition     = alltrue([for lt in aws_launch_template.worker : one(lt.block_device_mappings).device_name == "/dev/xvda"])
    error_message = "워커 디스크 장치 이름은 CP AMI가 아니라 선택한 워커 AMI에서 읽어야 합니다."
  }
  assert {
    condition     = aws_launch_template.worker["ai"].instance_type == "m7i.xlarge" && aws_launch_template.worker["api"].instance_type == "m7i.large"
    error_message = "공통 AMI를 사용해도 역할별 인스턴스 크기를 유지해야 합니다."
  }
  assert {
    condition     = aws_autoscaling_group.worker["api-ap-northeast-2a"].max_size == 3 && aws_autoscaling_group.worker["ai-ap-northeast-2b"].max_size == 3 && aws_autoscaling_group.worker["chat-ap-northeast-2b"].max_size == 2 && aws_autoscaling_group.worker["system-ap-northeast-2c"].max_size == 2 && alltrue([for asg in aws_autoscaling_group.worker : asg.desired_capacity == 1])
    error_message = "상한은 역할별 3·3·2·2로 열되 최초 desired는 각 1대를 유지해야 합니다."
  }
  assert {
    condition = alltrue([
      for role, lt in aws_launch_template.worker :
      strcontains(base64decode(lt.user_data), "ROLE=\"${role == "api" ? "general" : role}\"") &&
      strcontains(base64decode(lt.user_data), "REGION=\"ap-northeast-2\"") &&
      strcontains(base64decode(lt.user_data), "PARAMETER=\"/mulo-v3-prod/join/worker\"") &&
      strcontains(base64decode(lt.user_data), "kubeadm join --config") &&
      strcontains(base64decode(lt.user_data), "provider-id") &&
      length(base64decode(lt.user_data)) < 16384
    ])
    error_message = "각 Launch Template에 역할·SSM 경로·가입·providerID가 포함된 User Data를 연결해야 합니다."
  }
  assert {
    condition     = alltrue([for asg in aws_autoscaling_group.worker : length(asg.instance_refresh) == 0])
    error_message = "가입 자동화가 기존 노드를 drain 없이 교체하도록 바뀌어서는 안 됩니다."
  }
}

run "system_ec2_role_for_initial_ebs_csi" {
  command = plan
  variables {
    config = merge(var.config, { ebs_csi_use_node_role = true })
  }
  assert {
    condition     = length(aws_iam_role_policy_attachment.ebs_csi_system_node) == 1 && aws_iam_role_policy_attachment.ebs_csi_system_node[0].role == "mulo-v3-prod-system" && aws_iam_role_policy_attachment.ebs_csi_system_node[0].policy_arn == "arn:aws:iam::aws:policy/AmazonEBSCSIDriverPolicyV2"
    error_message = "초기 EBS CSI 권한은 system EC2 역할 하나에만 연결해야 합니다."
  }
  assert {
    condition     = one(aws_launch_template.worker["system"].metadata_options).http_tokens == "required" && one(aws_launch_template.worker["system"].metadata_options).http_put_response_hop_limit == 2 && alltrue([for role, lt in aws_launch_template.worker : one(lt.metadata_options).http_put_response_hop_limit == 1 if role != "system"]) && alltrue([for cp in aws_instance.control_plane : one(cp.metadata_options).http_put_response_hop_limit == 1])
    error_message = "system만 IMDSv2 hop limit 2를 사용하며 다른 워커와 CP는 1을 유지해야 합니다."
  }
}

run "node_role_access_is_opt_in" {
  command = plan
  assert {
    condition     = length(aws_iam_role_policy_attachment.ebs_csi_system_node) == 0 && alltrue([for lt in aws_launch_template.worker : one(lt.metadata_options).http_put_response_hop_limit == 1])
    error_message = "명시적으로 선택하지 않은 환경에는 EBS 노드 권한이나 IMDS hop 변경이 없어야 합니다."
  }
}

run "calico_vxlan_always_keeps_aws_checks" {
  command = plan
  assert {
    condition     = alltrue([for cp in aws_instance.control_plane : cp.source_dest_check != false])
    error_message = "Calico VXLAN Always 모드에서는 CP의 source/destination check를 끄지 않습니다."
  }
  assert {
    condition     = alltrue([for lt in aws_launch_template.worker : !strcontains(base64decode(lt.user_data), "source-dest-check")])
    error_message = "워커 부팅 스크립트가 source/destination check를 바꾸지 않아야 합니다."
  }
}

run "maximum_is_distributed_across_azs" {
  command = plan
  variables {
    config = merge(var.config, {
      workers = merge(var.config.workers, {
        ai = merge(var.config.workers.ai, {
          availability_zones = ["ap-northeast-2a", "ap-northeast-2b", "ap-northeast-2c"]
          min                = 3, desired = 3, max = 5
        })
      })
    })
  }
  assert {
    condition     = aws_autoscaling_group.worker["ai-ap-northeast-2a"].max_size == 2 && aws_autoscaling_group.worker["ai-ap-northeast-2b"].max_size == 2 && aws_autoscaling_group.worker["ai-ap-northeast-2c"].max_size == 1 && sum([for group in local.worker_groups : group.max if group.role == "ai"]) == 5
    error_message = "역할 전체 상한 5대를 세 AZ에 2·2·1로 분배해 총 상한을 넘지 않아야 합니다."
  }
}

run "ai_can_use_a_separate_image" {
  command = plan
  variables {
    config = merge(var.config, {
      workers = merge(var.config.workers, {
        ai = merge(var.config.workers.ai, { ami_id = "ami-0aaaaaaaaaaaaaaaa" })
      })
    })
  }
  override_data {
    target = data.aws_ami.worker["ai"]
    values = {
      id               = "ami-0aaaaaaaaaaaaaaaa"
      architecture     = "x86_64"
      root_device_type = "ebs"
      root_device_name = "/dev/xvdb"
    }
  }
  assert {
    condition     = aws_launch_template.worker["ai"].image_id == "ami-0aaaaaaaaaaaaaaaa" && one(aws_launch_template.worker["ai"].block_device_mappings).device_name == "/dev/xvdb" && aws_launch_template.worker["api"].image_id == "ami-0fedcba9876543210"
    error_message = "AI 전용 AMI를 지정할 때 다른 워커의 AMI는 바뀌지 않아야 합니다."
  }
}

run "reject_maximum_below_desired" {
  command = plan
  variables {
    config = merge(var.config, {
      workers = merge(var.config.workers, {
        ai = merge(var.config.workers.ai, { desired = 2, max = 1 })
      })
    })
  }
  expect_failures = [var.config]
}

run "reject_fractional_maximum" {
  command = plan
  variables {
    config = merge(var.config, {
      workers = merge(var.config.workers, {
        ai = merge(var.config.workers.ai, { max = 2.5 })
      })
    })
  }
  expect_failures = [var.config]
}

run "reject_invalid_worker_image_id" {
  command = plan
  variables {
    config = merge(var.config, {
      workers = merge(var.config.workers, {
        ai = merge(var.config.workers.ai, { ami_id = "worker-base" })
      })
    })
  }
  expect_failures = [var.config]
}

run "waf_rate_limit_and_body_size" {
  command = plan
  assert {
    condition     = !anytrue([for r in aws_wafv2_web_acl.web.rule : r.name == "rate-limit-per-ip"]) && length(aws_wafv2_web_acl.web.rule) == 1
    error_message = "waf_rate_limit을 주지 않으면 IP별 요청 수 제한 규칙 없이 공통 관리형 규칙만 있어야 합니다."
  }
  assert {
    condition = anytrue([for r in aws_wafv2_web_acl.web.rule : r.name == "AWSManagedRulesCommonRuleSet" && anytrue([
      for o in one(one(r.statement).managed_rule_group_statement).rule_action_override : o.name == "SizeRestrictions_BODY" && length(one(o.action_to_use).count) == 1
    ])])
    error_message = "이미지 업로드가 막히지 않도록 SizeRestrictions_BODY는 count로 바꿔야 합니다."
  }
}

run "system_node_role_for_loki_and_vault" {
  command = plan
  variables {
    config = merge(var.config, { loki_use_node_role = true, vault_kms_use_node_role = true })
  }
  assert {
    condition     = length(aws_iam_role_policy.loki_system_node) == 1 && length(aws_iam_role_policy.vault_kms_system_node) == 1
    error_message = "선택하면 system 역할에 Loki S3와 Vault KMS 권한을 붙여야 합니다."
  }
}

run "node_role_extras_are_opt_in" {
  command = plan
  assert {
    condition     = length(aws_iam_role_policy.loki_system_node) == 0 && length(aws_iam_role_policy.vault_kms_system_node) == 0
    error_message = "선택하지 않으면 system 역할에 Loki·KMS 권한이 없어야 합니다."
  }
}

run "backup_buckets_expire_old_data" {
  command = plan
  assert {
    condition     = toset(keys(aws_s3_bucket_lifecycle_configuration.storage)) == toset(["loki", "etcd-backup", "vault-backup"]) && one(aws_s3_bucket_lifecycle_configuration.storage["etcd-backup"].rule[0].expiration).days == 30 && length(aws_s3_bucket_lifecycle_configuration.storage["loki"].rule[0].expiration) == 0
    error_message = "Loki는 이전 버전만, 백업 버킷은 30일 뒤 만료해야 합니다. images는 자동 삭제하지 않습니다."
  }
}

run "etcd_volume_per_control_plane" {
  command = plan
  assert {
    condition = length(aws_ebs_volume.etcd) == 3 && alltrue([
      for key, volume in aws_ebs_volume.etcd :
      volume.availability_zone == aws_instance.control_plane[key].availability_zone && volume.type == "gp3" && volume.encrypted && volume.size == 20
    ]) && alltrue([for a in aws_volume_attachment.etcd : a.device_name == "/dev/sdf"])
    error_message = "CP마다 같은 AZ에 암호화된 etcd 전용 gp3 볼륨을 붙여야 합니다."
  }
}

run "control_plane_timers" {
  command = plan
  assert {
    condition     = aws_ssm_document.control_plane_timers.document_type == "Command" && aws_ssm_association.control_plane_timers.name == "mulo-v3-prod-control-plane-timers"
    error_message = "CP timer 설치 문서와 실행 연결이 있어야 합니다."
  }
  assert {
    condition     = toset([for t in aws_ssm_association.control_plane_timers.targets : t.key]) == toset(["tag:Role", "tag:kubernetes.io/cluster/mulo-v3-prod"])
    error_message = "timer는 이 클러스터의 CP에만 설치해야 합니다."
  }
}

run "autoscaler_node_role_is_opt_in" {
  command = plan
  assert {
    condition     = length(aws_iam_role_policy.autoscaler_system_node) == 0
    error_message = "선택하지 않으면 system 역할에 ASG 변경 권한이 없어야 합니다."
  }
}

run "autoscaler_node_role" {
  command = plan
  variables {
    config = merge(var.config, { cluster_autoscaler_use_node_role = true })
  }
  assert {
    condition     = length(aws_iam_role_policy.autoscaler_system_node) == 1
    error_message = "선택하면 system 역할에 CA 권한을 붙여야 합니다."
  }
}
