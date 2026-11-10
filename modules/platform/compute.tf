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

# AMI는 운영자가 선택합니다. user_data, remote-exec, OS 부트스트랩은 의도적으로 없습니다.
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
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 30
    encrypted   = true
  }

  tags = {
    Name = "${local.name}-cp-${each.key}", Role = "control-plane", (local.cluster_tag) = "owned"
  }
}

resource "aws_launch_template" "worker" {
  for_each               = var.config.workers
  name_prefix            = "${local.name}-${each.key}-"
  image_id               = data.aws_ami.node.id
  instance_type          = each.value.instance_type
  update_default_version = true
  iam_instance_profile {
    name = aws_iam_instance_profile.node[each.key].name
  }

  network_interfaces {
    associate_public_ip_address = false
    delete_on_termination       = true
    security_groups             = [aws_security_group.role[each.key].id, aws_security_group.role["overlay"].id]
  }

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = data.aws_ami.node.root_device_name
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
      Name = "${local.name}-${each.key}", Role = each.key, (local.cluster_tag) = "owned"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name = "${local.name}-${each.key}-root"
    }
  }
}

# ASG 필수 상한은 목표 대수와 같게 두어 구축 중 추가 확장을 막습니다.
resource "aws_autoscaling_group" "worker" {
  for_each                  = local.worker_groups
  name                      = "${local.name}-${each.key}"
  min_size                  = each.value.min
  desired_capacity          = each.value.desired
  max_size                  = each.value.desired
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
      Name                                                                        = "${local.name}-${each.key}"
      (local.cluster_tag)                                                         = "owned"
      "k8s.io/cluster-autoscaler/enabled"                                         = "true"
      "k8s.io/cluster-autoscaler/${local.name}"                                   = "owned"
      "k8s.io/cluster-autoscaler/node-template/label/node-group"                  = each.value.role
      "k8s.io/cluster-autoscaler/node-template/label/topology.kubernetes.io/zone" = each.value.az
    }

    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  # 실제 kubelet 라벨/taint 설정은 별도 작업입니다. 이 태그는 CA의 용량 예측용입니다.
  dynamic "tag" {
    for_each = each.value.role == "api" ? {
      } : {
      dedicated = "${each.value.role}:NoSchedule"
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

