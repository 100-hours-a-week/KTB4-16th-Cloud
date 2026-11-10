resource "aws_route53_zone" "public" {
  count         = var.config.route53_zone == null ? 0 : 1
  name          = var.config.route53_zone
  comment       = "${local.name} migration hosted zone; delegation and cutover are separate"
  force_destroy = false
}

# DataSync의 목적지 images 버킷 접근 역할만 생성합니다.
# GCS 자격 증명, 위치, Task 및 실제 전송 실행은 별도 단계입니다.
resource "aws_iam_role" "datasync" {
  count = var.config.enable_datasync_iam ? 1 : 0
  name  = "${local.name}-datasync-images"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "datasync.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = var.config.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:${local.partition}:datasync:${var.region}:${var.config.account_id}:*" }
      }
    }]
  })
}

resource "aws_iam_role_policy" "datasync_images" {
  count = var.config.enable_datasync_iam ? 1 : 0
  role  = aws_iam_role.datasync[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = ["s3:GetBucketLocation", "s3:ListBucket", "s3:ListBucketMultipartUploads"]
        Resource  = "arn:${local.partition}:s3:::${aws_s3_bucket.storage["images"].bucket}"
        Condition = { StringEquals = { "aws:ResourceAccount" = var.config.account_id } }
      },
      {
        Effect = "Allow"
        Action = [
          "s3:AbortMultipartUpload", "s3:DeleteObject", "s3:GetObject", "s3:GetObjectTagging",
          "s3:GetObjectVersion", "s3:GetObjectVersionTagging", "s3:ListMultipartUploadParts",
          "s3:PutObject", "s3:PutObjectTagging"
        ]
        Resource  = "arn:${local.partition}:s3:::${aws_s3_bucket.storage["images"].bucket}/*"
        Condition = { StringEquals = { "aws:ResourceAccount" = var.config.account_id } }
      }
    ]
  })
}
