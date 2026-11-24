# 장애 대응 훈련(AWS FIS)용 실행 역할, 중단 조건 알람, 실험 템플릿.
# 템플릿은 만들어 두기만 해서는 아무 일도 하지 않는다. 콘솔이나 `aws fis start-experiment`로 시작할 때만 장애를 넣는다.
#
# 실험(모두 10분 동안 장애를 넣고 끝나면 원래대로 돌아온다)
# - az-outage-<AZ>   : 그 AZ의 private·data 서브넷 네트워크 차단 + 그 AZ의 PVC용 EBS I/O 멈춤
#                      + 워커 ASG가 그 AZ에 인스턴스를 못 띄움 + 그 AZ에 주 DB가 있는 RDS를 다른 AZ로 failover
# - stop-general-<AZ>: 그 AZ의 general 워커(frontend·backend·Envoy)를 멈춘다. ASG가 새 인스턴스로 교체한다.

data "aws_availability_zones" "fis" {
  state = "available"
}

locals {
  # ASG 장애 액션은 AZ 이름이 아니라 AZ ID(apne2-az1 등)를 받는다.
  fis_zone_id = zipmap(data.aws_availability_zones.fis.names, data.aws_availability_zones.fis.zone_ids)
  # 지금 주 DB가 그 AZ에 있는 RDS. failover하면 주 DB AZ가 바뀌므로 다음 plan에서 다시 계산된다.
  fis_rds_by_az = {
    for az in var.config.azs : az => [for k, db in aws_db_instance.database : db.arn if db.availability_zone == az]
  }
  # Pod는 노드가 죽고 300초 뒤에 옮겨지므로, 다른 AZ로 이동·노드 증설까지 보려면 10분은 필요하다.
  fis_fault_duration = "PT10M"
}

resource "aws_cloudwatch_log_group" "fis" {
  name              = "/aws/fis/${local.name}"
  retention_in_days = 30
}

resource "aws_iam_role" "fis" {
  name = "${local.name}-fis"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "fis.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = var.config.account_id } }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "fis" {
  for_each = toset([
    "arn:aws:iam::aws:policy/service-role/AWSFaultInjectionSimulatorEC2Access",
    "arn:aws:iam::aws:policy/service-role/AWSFaultInjectionSimulatorNetworkAccess",
    "arn:aws:iam::aws:policy/service-role/AWSFaultInjectionSimulatorRDSAccess",
  ])
  role       = aws_iam_role.fis.name
  policy_arn = each.value
}

# 관리형 정책에 없는 EBS I/O 멈춤, ASG 용량 부족 주입, 실험 로그 전송 권한.
resource "aws_iam_role_policy" "fis" {
  name = "${local.name}-fis-extra"
  role = aws_iam_role.fis.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["ec2:PauseVolumeIO", "ec2:DescribeVolumes"], Resource = "*" },
      { Effect = "Allow", Action = ["ec2:InjectApiError", "autoscaling:DescribeAutoScalingGroups"], Resource = "*" },
      { Effect = "Allow", Action = ["logs:CreateLogDelivery", "logs:PutResourcePolicy", "logs:DescribeResourcePolicies", "logs:DescribeLogGroups"], Resource = "*" },
    ]
  })
}

# 중단 조건: 사용자 입구(web ALB)의 5xx 비율이 2분 연속 50%를 넘으면 실험을 멈춘다.
resource "aws_cloudwatch_metric_alarm" "fis_stop" {
  alarm_name          = "${local.name}-fis-stop-5xx"
  alarm_description   = "FIS 중단 조건: web ALB 5xx 비율이 2분 연속 50% 초과"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 50
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "ratio"
    expression  = "100 * (FILL(elb5xx, 0) + FILL(target5xx, 0)) / FILL(requests, 1)"
    label       = "5xx 비율(%)"
    return_data = true
  }
  dynamic "metric_query" {
    for_each = { requests = "RequestCount", elb5xx = "HTTPCode_ELB_5XX_Count", target5xx = "HTTPCode_Target_5XX_Count" }
    content {
      id = metric_query.key
      metric {
        namespace   = "AWS/ApplicationELB"
        metric_name = metric_query.value
        period      = 60
        stat        = "Sum"
        dimensions  = { LoadBalancer = aws_lb.web.arn_suffix }
      }
    }
  }
}

resource "aws_fis_experiment_template" "az_outage" {
  for_each    = local.azs
  description = "AZ ${each.key} 장애 5분: 네트워크 차단, EBS 멈춤, ASG 증설 실패, RDS failover"
  role_arn    = aws_iam_role.fis.arn
  tags        = { Name = "${local.name}-fis-az-outage-${each.key}" }

  stop_condition {
    source = "aws:cloudwatch:alarm"
    value  = aws_cloudwatch_metric_alarm.fis_stop.arn
  }
  experiment_options {
    account_targeting            = "single-account"
    empty_target_resolution_mode = "skip"
  }
  log_configuration {
    log_schema_version = 2
    cloudwatch_logs_configuration {
      log_group_arn = "${aws_cloudwatch_log_group.fis.arn}:*"
    }
  }

  # 그 AZ의 노드(private)와 DB(data) 서브넷을 네트워크 ACL로 막는다. 노드는 켜진 채 고립된다.
  action {
    name      = "network-blackhole"
    action_id = "aws:network:disrupt-connectivity"
    parameter {
      key   = "duration"
      value = local.fis_fault_duration
    }
    parameter {
      key   = "scope"
      value = "all"
    }
    target {
      key   = "Subnets"
      value = "az-subnets"
    }
  }
  target {
    name           = "az-subnets"
    resource_type  = "aws:ec2:subnet"
    selection_mode = "ALL"
    resource_arns  = [aws_subnet.private[each.key].arn, aws_subnet.data[each.key].arn]
  }

  # 그 AZ의 PVC용 EBS(EBS CSI가 만든 볼륨) I/O를 멈춘다. Redis·Vault·Prometheus·Loki 볼륨이 대상이다.
  action {
    name      = "ebs-pause"
    action_id = "aws:ebs:pause-volume-io"
    parameter {
      key   = "duration"
      value = local.fis_fault_duration
    }
    target {
      key   = "Volumes"
      value = "az-pvc-volumes"
    }
  }
  target {
    name           = "az-pvc-volumes"
    resource_type  = "aws:ec2:ebs-volume"
    selection_mode = "ALL"
    resource_tag {
      key   = "ebs.csi.aws.com/cluster"
      value = "true"
    }
    # EBS 볼륨을 태그로 고를 때 FIS는 AZ를 파라미터로 요구한다.
    parameters = {
      availabilityZoneIdentifier = each.key
    }
  }

  # 워커 ASG가 그 AZ에 새 인스턴스를 띄우려 하면 용량 부족 오류를 받는다(Cluster Autoscaler는 다른 AZ로 늘려야 한다).
  action {
    name      = "asg-no-capacity"
    action_id = "aws:ec2:asg-insufficient-instance-capacity-error"
    parameter {
      key   = "availabilityZoneIdentifiers"
      value = local.fis_zone_id[each.key]
    }
    parameter {
      key   = "duration"
      value = local.fis_fault_duration
    }
    target {
      key   = "AutoScalingGroups"
      value = "worker-asgs"
    }
  }
  # ARN은 템플릿당 5개까지라 태그로 고른다. 이 AZ의 워커 ASG만 대상이다.
  target {
    name           = "worker-asgs"
    resource_type  = "aws:ec2:autoscaling-group"
    selection_mode = "ALL"
    resource_tag {
      key   = "k8s.io/cluster-autoscaler/${local.name}"
      value = "owned"
    }
    resource_tag {
      key   = "k8s.io/cluster-autoscaler/node-template/label/topology.kubernetes.io/zone"
      value = each.key
    }
  }

  # 그 AZ에 주 DB가 있는 RDS만 다른 AZ로 failover한다(없으면 이 액션은 빠진다).
  dynamic "action" {
    for_each = length(local.fis_rds_by_az[each.key]) > 0 ? [1] : []
    content {
      name      = "rds-failover"
      action_id = "aws:rds:reboot-db-instances"
      parameter {
        key   = "forceFailover"
        value = "true"
      }
      target {
        key   = "DBInstances"
        value = "az-primary-dbs"
      }
    }
  }
  dynamic "target" {
    for_each = length(local.fis_rds_by_az[each.key]) > 0 ? [1] : []
    content {
      name           = "az-primary-dbs"
      resource_type  = "aws:rds:db"
      selection_mode = "ALL"
      resource_arns  = local.fis_rds_by_az[each.key]
    }
  }
}

resource "aws_fis_experiment_template" "stop_general" {
  for_each    = local.azs
  description = "AZ ${each.key}의 general 워커(frontend·backend·Envoy) 정지. ASG가 새 인스턴스로 교체"
  role_arn    = aws_iam_role.fis.arn
  tags        = { Name = "${local.name}-fis-stop-general-${each.key}" }

  stop_condition {
    source = "aws:cloudwatch:alarm"
    value  = aws_cloudwatch_metric_alarm.fis_stop.arn
  }
  experiment_options {
    account_targeting            = "single-account"
    empty_target_resolution_mode = "skip"
  }
  log_configuration {
    log_schema_version = 2
    cloudwatch_logs_configuration {
      log_group_arn = "${aws_cloudwatch_log_group.fis.arn}:*"
    }
  }

  action {
    name      = "stop-general"
    action_id = "aws:ec2:stop-instances"
    # 5분 뒤 다시 켠다. 그 전에 ASG가 멈춘 인스턴스를 종료·교체했으면 실패로 보지 않는다.
    parameter {
      key   = "startInstancesAfterDuration"
      value = local.fis_fault_duration
    }
    parameter {
      key   = "completeIfInstancesTerminated"
      value = "true"
    }
    target {
      key   = "Instances"
      value = "general-workers"
    }
  }
  target {
    name           = "general-workers"
    resource_type  = "aws:ec2:instance"
    selection_mode = "ALL"
    resource_tag {
      key   = "Role"
      value = "general"
    }
    filter {
      path   = "Placement.AvailabilityZone"
      values = [each.key]
    }
    filter {
      path   = "State.Name"
      values = ["running"]
    }
  }
}
