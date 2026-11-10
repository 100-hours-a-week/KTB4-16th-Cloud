# RDS 인스턴스와 DB 서브넷 그룹을 생성합니다. 기존 데이터는 이전하지 않습니다.
resource "aws_db_subnet_group" "main" {
  name       = local.name
  subnet_ids = [for az in var.config.azs : aws_subnet.data[az].id]
}

resource "aws_db_instance" "database" {
  for_each                    = var.config.databases
  identifier                  = "${local.name}-${each.key}"
  engine                      = each.value.engine
  engine_version              = each.value.engine_version
  instance_class              = each.value.instance_class
  db_name                     = each.value.snapshot_identifier == null ? each.value.database_name : null
  username                    = each.value.snapshot_identifier == null ? each.value.username : null
  manage_master_user_password = true
  snapshot_identifier         = each.value.snapshot_identifier
  allocated_storage           = each.value.allocated_storage
  max_allocated_storage       = each.value.max_allocated_storage
  storage_type                = "gp3"
  storage_encrypted           = true
  multi_az                    = each.value.multi_az
  publicly_accessible         = false
  db_subnet_group_name        = aws_db_subnet_group.main.name
  vpc_security_group_ids      = [aws_security_group.role["database"].id]
  backup_retention_period     = 7
  backup_window               = "18:00-19:00"
  maintenance_window          = "sun:19:00-sun:20:00"
  deletion_protection         = var.config.enable_deletion_protection
  skip_final_snapshot         = false
  # 재생성 후 다시 삭제할 때는 기존 최종 스냅샷 이름과 충돌하지 않게 조정합니다.
  final_snapshot_identifier  = "${local.name}-${each.key}-final"
  copy_tags_to_snapshot      = true
  auto_minor_version_upgrade = true
  apply_immediately          = false
}


