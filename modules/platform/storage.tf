resource "aws_s3_bucket" "storage" {
  for_each      = toset(["images", "loki", "etcd-backup", "vault-backup"])
  bucket        = "${local.name}-${var.config.account_id}-${each.key}"
  force_destroy = false
}

resource "aws_s3_bucket_public_access_block" "storage" {
  for_each                = aws_s3_bucket.storage
  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "storage" {
  for_each = aws_s3_bucket.storage
  bucket   = each.value.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "storage" {
  for_each = aws_s3_bucket.storage
  bucket   = each.value.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_policy" "tls" {
  for_each = aws_s3_bucket.storage
  bucket   = each.value.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid = "DenyInsecureTransport", Effect = "Deny", Principal = "*", Action = "s3:*", Resource = [each.value.arn, "${each.value.arn}/*"], Condition = {
        Bool = {
          "aws:SecureTransport" = "false"
        }
      }
      }
    ]
    }
  )
}

resource "aws_ecr_repository" "app" {
  for_each             = var.config.ecr_repositories
  name                 = "${local.name}/${each.key}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false
  encryption_configuration {
    encryption_type = "AES256"
  }

  image_scanning_configuration {
    scan_on_push = true
  }
}


# 버전 관리가 켜진 버킷은 삭제·덮어쓴 객체의 이전 버전이 계속 쌓입니다.
# Loki는 compactor가 보존 기간이 지난 청크를 지우므로 이전 버전만 정리하면 됩니다.
# etcd·Vault 백업은 1시간 단위 스냅샷이라 오래된 것부터 만료합니다.
# images는 사용자 데이터라 자동 삭제 대상에서 뺍니다.
resource "aws_s3_bucket_lifecycle_configuration" "storage" {
  for_each = {
    loki         = null
    etcd-backup  = var.config.backup_retention_days
    vault-backup = var.config.backup_retention_days
  }
  bucket = aws_s3_bucket.storage[each.key].id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"
    filter {}

    dynamic "expiration" {
      for_each = each.value == null ? [] : [each.value]
      content {
        days = expiration.value
      }
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.storage]
}
