data "aws_ami" "node" {
  filter {
    name   = "image-id"
    values = [var.config.ami_id]
  }
  lifecycle {
    postcondition {
      condition     = self.architecture == "x86_64" && self.root_device_type == "ebs"
      error_message = "노드 AMI는 x86_64 EBS 기반이어야 합니다."
    }
  }
}

# CP AMI는 기존 입력을 유지합니다. 워커용 AMI를 바꿔도 CP를 교체하지 않습니다.
resource "aws_instance" "control_plane" {
  for_each                    = local.control_planes
  ami                         = data.aws_ami.node.id
  instance_type               = var.config.control_plane_type
  availability_zone           = each.value
  subnet_id                   = aws_subnet.private[each.value].id
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.role["control-plane"].id, aws_security_group.role["overlay"].id]
  iam_instance_profile        = aws_iam_instance_profile.node["control-plane"].name
  disable_api_termination     = var.config.enable_deletion_protection
  # Calico는 VXLAN Always 모드라 Pod 패킷이 항상 노드 IP로 캡슐화됩니다. source/dest check는 기본값(true)을 유지합니다.
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    # AMI 스냅샷보다 작으면 EC2를 만들 수 없습니다. 워커 AMI(50GB)를 같이 쓰므로 기본 50입니다.
    volume_size = var.config.control_plane_root_gb
    encrypted   = true
  }

  tags = {
    Name = "${local.name}-cp-${each.key}", Role = "control-plane", (local.cluster_tag) = "owned"
  }
}

# 워커마다 AMI를 조회합니다. 입력을 생략한 환경은 기존 공통 AMI를 사용합니다.
data "aws_ami" "worker" {
  for_each = var.config.workers
  filter {
    name   = "image-id"
    values = [coalesce(each.value.ami_id, var.config.ami_id)]
  }
  lifecycle {
    postcondition {
      condition     = self.architecture == "x86_64" && self.root_device_type == "ebs"
      error_message = "워커 AMI는 x86_64 EBS 기반이어야 합니다."
    }
  }
}

# AWS에 이미 있는 리소스 키는 유지하고 Kubernetes에서 사용하는 역할 이름만 맞춥니다.
locals {
  worker_workloads = { for role in keys(var.config.workers) : role => role == "api" ? "general" : role }
}

resource "aws_launch_template" "worker" {
  for_each               = var.config.workers
  name_prefix            = "${local.name}-${each.key}-"
  image_id               = data.aws_ami.worker[each.key].id
  instance_type          = each.value.instance_type
  update_default_version = true

  # 같은 워커 AMI를 써도 역할별 값을 전달하므로 label·taint가 구분됩니다.
  # 실제 토큰은 이미지나 Terraform state에 넣지 않고 부팅 시 SSM에서 읽습니다.
  user_data = base64encode(templatefile("${path.module}/templates/worker-join.sh.tftpl", {
    region         = var.region
    node_group     = local.worker_workloads[each.key]
    parameter_name = "/${local.name}/join/worker"
    # 검토한 설치 스크립트를 압축해 포함한다. 부팅할 때 Git의 최신 코드를 받지 않는다.
    ecr_setup_base64 = base64gzip(file("${path.module}/templates/install-worker-ecr.sh"))
  }))

  iam_instance_profile {
    name = aws_iam_instance_profile.node[each.key].name
  }

  network_interfaces {
    associate_public_ip_address = false
    delete_on_termination       = true
    security_groups             = [aws_security_group.role[each.key].id, aws_security_group.role["overlay"].id]
  }

  metadata_options {
    http_tokens = "required"
    # Pod가 EC2 역할을 쓰려면 2가 필요합니다(컨테이너 네트워크에서 IMDS까지 한 홉 더).
    # system: EBS CSI controller·Loki·Vault KMS, api: backend의 images S3. 다른 워커와 CP는 1을 유지합니다.
    # Launch Template만 바뀌므로 이미 떠 있는 ASG 인스턴스는 별도로 같은 값을 적용합니다(modify-instance-metadata-options).
    # 워커 그룹별 imds_hop_limit을 지정하면 그 값을 우선합니다(ai: AI가 images S3 사진을 읽음).
    http_put_response_hop_limit = coalesce(each.value.imds_hop_limit, (each.key == "system" && var.config.ebs_csi_use_node_role) || (each.key == "api" && var.config.images_s3_use_node_role) ? 2 : 1)
  }

  block_device_mappings {
    device_name = data.aws_ami.worker[each.key].root_device_name
    ebs {
      volume_type           = "gp3"
      volume_size           = each.value.root_volume_gb
      encrypted             = true
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${local.name}-${local.worker_workloads[each.key]}", Role = local.worker_workloads[each.key], (local.cluster_tag) = "owned"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name = "${local.name}-${local.worker_workloads[each.key]}-root"
    }
  }
}

# 역할별 max를 AZ별로 나눈 상한을 사용합니다. max 생략 시 기존 desired를 상한으로 유지합니다.
resource "aws_autoscaling_group" "worker" {
  for_each                  = local.worker_groups
  name                      = "${local.name}-${each.key}"
  min_size                  = each.value.min
  desired_capacity          = each.value.desired
  max_size                  = each.value.max
  vpc_zone_identifier       = [aws_subnet.private[each.value.az].id]
  health_check_type         = "EC2"
  health_check_grace_period = 600
  # kubeadm/Envoy 설치 전에도 EC2 기반 인프라 생성은 완료할 수 있습니다.
  target_group_arns = each.value.role == "api" ? [aws_lb_target_group.envoy.arn] : []
  launch_template {
    id      = aws_launch_template.worker[each.value.role].id
    version = tostring(aws_launch_template.worker[each.value.role].latest_version)
  }

  dynamic "tag" {
    for_each = {
      Name                                                                        = "${local.name}-${local.worker_workloads[each.value.role]}"
      Role                                                                        = local.worker_workloads[each.value.role]
      (local.cluster_tag)                                                         = "owned"
      "k8s.io/cluster-autoscaler/enabled"                                         = "true"
      "k8s.io/cluster-autoscaler/${local.name}"                                   = "owned"
      "k8s.io/cluster-autoscaler/node-template/label/workload"                    = local.worker_workloads[each.value.role]
      "k8s.io/cluster-autoscaler/node-template/label/topology.kubernetes.io/zone" = each.value.az
    }

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  # CA의 용량 예측용 태그입니다. 실제 label·taint는 위 User Data가 가입할 때 등록합니다.
  dynamic "tag" {
    for_each = {
      dedicated = "${local.worker_workloads[each.value.role]}:NoSchedule"
    }

    content {
      key                 = "k8s.io/cluster-autoscaler/node-template/taint/${tag.key}"
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    ignore_changes = [desired_capacity]
  }

  # drain 연동 없는 자동 instance_refresh를 실행하지 않습니다.
  depends_on = [aws_route.nat, terraform_data.guardrails]
}

