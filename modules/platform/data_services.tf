# RDS 인스턴스와 DB 서브넷 그룹을 생성합니다. 기존 데이터는 이전하지 않습니다.
resource "aws_db_subnet_group" "main" {
  name       = local.name
  subnet_ids = [for az in var.config.azs : aws_subnet.data[az].id]
}

ephemeral "aws_ssm_parameter" "db_master_password" {
  for_each        = var.config.databases
  arn             = "arn:${local.partition}:ssm:${var.region}:${var.config.account_id}:parameter/${local.name}/db/${each.key}/master-password"
  with_decryption = true
}

# DB마다 전용 파라미터 그룹을 둡니다. 기본 그룹(default.*)은 수정할 수 없기 때문입니다.
# 값은 tfvars databases.<DB>.parameters로 넣습니다. 기본은 pending-reboot이며 재부팅해야 반영됩니다.
# immediate_parameters에 이름을 넣은 동적 파라미터만 재부팅 없이 바로 적용합니다(새 DB 연결부터 반영).
resource "aws_db_parameter_group" "database" {
  for_each    = var.config.databases
  name        = "${local.name}-${each.key}"
  family      = each.value.engine == "postgres" ? "postgres${split(".", each.value.engine_version)[0]}" : "${each.value.engine}${each.value.engine_version}"
  description = "${local.name} ${each.key} parameters"

  dynamic "parameter" {
    for_each = each.value.parameters
    content {
      name         = parameter.key
      value        = parameter.value
      apply_method = contains(each.value.immediate_parameters, parameter.key) ? "immediate" : "pending-reboot"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "database" {
  for_each       = var.config.databases
  identifier     = "${local.name}-${each.key}"
  engine         = each.value.engine
  engine_version = each.value.engine_version
  instance_class = each.value.instance_class
  db_name        = each.value.snapshot_identifier == null ? each.value.database_name : null
  username       = each.value.snapshot_identifier == null ? each.value.username : null
  # 비밀번호는 직접 정해서 Vault에 넣습니다. RDS 관리형 비밀번호(Secrets Manager)는 7일마다 자동으로 바뀌어
  # Vault에 넣은 값이 낡고 앱 연결이 끊기므로 쓰지 않습니다.
  # 비밀번호 원본은 SSM SecureString /<이름>/db/<DB>/master-password 입니다. apply 전에 사람이 직접 넣습니다.
  # ephemeral로 읽어 write-only 인자로만 넘기므로 state와 plan 파일에 남지 않습니다.
  # 바꿀 때는 SSM 값을 고치고 db_password_version을 1 올린 뒤 apply합니다.
  password_wo             = ephemeral.aws_ssm_parameter.db_master_password[each.key].value
  password_wo_version     = var.config.db_password_version
  snapshot_identifier     = each.value.snapshot_identifier
  allocated_storage       = each.value.allocated_storage
  max_allocated_storage   = each.value.max_allocated_storage
  storage_type            = "gp3"
  storage_encrypted       = true
  multi_az                = each.value.multi_az
  publicly_accessible     = false
  db_subnet_group_name    = aws_db_subnet_group.main.name
  parameter_group_name    = aws_db_parameter_group.database[each.key].name
  vpc_security_group_ids  = [aws_security_group.role["database"].id]
  backup_retention_period = 7
  backup_window           = "18:00-19:00"
  maintenance_window      = "sun:19:00-sun:20:00"
  deletion_protection     = var.config.enable_deletion_protection
  # 환경을 통째로 지울 때만 true로 둡니다. 평소에는 삭제 시 최종 스냅샷을 남깁니다.
  skip_final_snapshot = var.config.skip_final_snapshot
  # 자동 백업도 DB와 함께 지웁니다(기본값과 같음).
  delete_automated_backups = true
  # 재생성 후 다시 삭제할 때는 기존 최종 스냅샷 이름과 충돌하지 않게 조정합니다.
  final_snapshot_identifier  = "${local.name}-${each.key}-final"
  copy_tags_to_snapshot      = true
  auto_minor_version_upgrade = true
  # 평소에는 정비 시간에 반영합니다. 크기·Multi-AZ 변경을 바로 반영해야 할 때만 true로 둡니다.
  apply_immediately = var.config.rds_apply_immediately
}


