data "aws_partition" "current" {
}

locals {
  partition = data.aws_partition.current.partition
  ec2_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow", Principal = {
        Service = "ec2.amazonaws.com"
      }, Action = "sts:AssumeRole"
      }
    ]
    }
  )
}

resource "aws_iam_role" "node" {
  for_each           = local.node_roles
  name               = "${local.name}-${each.key}"
  assume_role_policy = local.ec2_trust
}

resource "aws_iam_instance_profile" "node" {
  for_each = local.node_roles
  name     = aws_iam_role.node[each.key].name
  role     = aws_iam_role.node[each.key].name
}

resource "aws_iam_role_policy_attachment" "ssm" {
  for_each   = local.node_roles
  role       = aws_iam_role.node[each.key].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# 초기 구축에서 선택한 EC2 역할 인증입니다. system 역할에만 EBS 권한을 연결합니다.
# IAM 역할의 정책 추가는 이미 실행 중인 EC2에도 적용되며 인스턴스를 교체하지 않습니다.
# 나중에 Pod 전용 IAM으로 전환할 때 ebs_csi_use_node_role을 false로 바꾸면 분리됩니다.
resource "aws_iam_role_policy_attachment" "ebs_csi_system_node" {
  count      = var.config.ebs_csi_use_node_role ? 1 : 0
  role       = aws_iam_role.node["system"].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEBSCSIDriverPolicyV2"
}

# Loki도 초기 구축에서는 system 노드에서 실행되며 같은 EC2 역할로 S3에 접근합니다.
# Pod 전용 IAM(OIDC)으로 전환하면 loki_use_node_role을 false로 바꿔 분리합니다.
resource "aws_iam_role_policy" "loki_system_node" {
  count = var.config.loki_use_node_role ? 1 : 0
  name  = "${local.name}-system-loki"
  role  = aws_iam_role.node["system"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:ListBucket"], Resource = aws_s3_bucket.storage["loki"].arn },
      { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], Resource = "${aws_s3_bucket.storage["loki"].arn}/*" }
    ]
  })
}

# backend(workload=general, api 역할 노드)가 같은 EC2 역할로 images 버킷에 접근합니다.
# 같은 노드의 다른 Pod도 이 권한을 쓸 수 있으므로, Pod 전용 IAM(OIDC)으로 전환하면 images_s3_use_node_role을 false로 바꿔 분리합니다.
resource "aws_iam_role_policy" "images_api_node" {
  count = var.config.images_s3_use_node_role ? 1 : 0
  name  = "${local.name}-api-images"
  role  = aws_iam_role.node["api"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:ListBucket", "s3:GetBucketLocation"], Resource = aws_s3_bucket.storage["images"].arn },
      { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"], Resource = "${aws_s3_bucket.storage["images"].arn}/*" }
    ]
  })
}

# AI(workload=ai, ai 역할 노드)가 images 버킷의 사진을 사전 서명 URL로 읽습니다. 읽기만 허용합니다.
# 콘솔에서 먼저 만든 인라인 정책(ai-photos-read)을 같은 이름으로 관리합니다(environments/prod/imports.tf에서 가져옴).
resource "aws_iam_role_policy" "images_ai_node_read" {
  name = "ai-photos-read"
  role = aws_iam_role.node["ai"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:GetObject"], Resource = "${aws_s3_bucket.storage["images"].arn}/*" }
    ]
  })
}

# Vault Pod가 system 노드에서 KMS auto-unseal을 쓰도록 같은 EC2 역할에 이 키만 허용합니다.
# 이 권한을 준 뒤 Vault values에 seal "awskms"를 추가하고 seal migration을 한 번 해야 수동 unseal이 없어집니다.
resource "aws_iam_role_policy" "vault_kms_system_node" {
  count = var.config.vault_kms_use_node_role ? 1 : 0
  name  = "${local.name}-system-vault-kms"
  role  = aws_iam_role.node["system"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey"], Resource = aws_kms_key.vault.arn }
    ]
  })
}

# Cluster Autoscaler도 system 노드에서 실행되며 같은 EC2 역할로 이 클러스터의 워커 ASG만 늘리고 줄입니다.
# 조회 권한은 리소스 단위로 좁힐 수 없어 *이고, 크기 변경·종료는 이 모듈의 ASG ARN으로 한정합니다.
resource "aws_iam_role_policy" "autoscaler_system_node" {
  count = var.config.cluster_autoscaler_use_node_role ? 1 : 0
  name  = "${local.name}-system-cluster-autoscaler"
  role  = aws_iam_role.node["system"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups", "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations", "autoscaling:DescribeScalingActivities",
          "autoscaling:DescribeTags", "ec2:DescribeImages", "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplateVersions", "ec2:GetInstanceTypesFromInstanceRequirements"
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["autoscaling:SetDesiredCapacity", "autoscaling:TerminateInstanceInAutoScalingGroup"]
        Resource = [for asg in aws_autoscaling_group.worker : asg.arn]
      }
    ]
  })
}

resource "aws_iam_role_policy" "ecr" {
  for_each = local.node_roles
  role     = aws_iam_role.node[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*"
      },
      {
        Effect = "Allow", Action = ["ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage"], Resource = [for r in aws_ecr_repository.app : r.arn]
      }

    ]
    }
  )
}

resource "aws_iam_role_policy" "join_read" {
  for_each = local.node_roles
  role     = aws_iam_role.node[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow", Action = ["ssm:GetParameter", "ssm:GetParameters"], Resource = "arn:${local.partition}:ssm:${var.region}:${var.config.account_id}:parameter/${local.name}/join/*"
      }
    ]
    }
  )
}

# AmazonSSMManagedInstanceCore는 ssm:GetParameter(s)를 모든 파라미터에 허용합니다.
# 그대로 두면 노드(그리고 IMDS hop limit 2인 system 노드의 Pod)가 DB 마스터 비밀번호를 읽을 수 있으므로
# 노드 역할에서는 /<이름>/db/* 읽기와 경로 단위 조회를 명시적으로 막습니다(Deny가 Allow보다 우선).
# DB 비밀번호는 Mac의 관리자 로그인에서만 읽고, 앱은 Vault → ESO로만 받습니다.
resource "aws_iam_role_policy" "deny_db_secrets" {
  for_each = local.node_roles
  role     = aws_iam_role.node[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DenyDbParameterRead"
        Effect   = "Deny"
        Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParameterHistory"]
        Resource = "arn:${local.partition}:ssm:${var.region}:${var.config.account_id}:parameter/${local.name}/db/*"
      },
      {
        Sid      = "DenyParameterPathRead"
        Effect   = "Deny"
        Action   = ["ssm:GetParametersByPath"]
        Resource = "*"
      }
    ]
    }
  )
}

# Parameter 자체/토큰 값은 생성하지 않습니다. 고객 KMS 키 사용 시 별도 Decrypt 권한이 필요합니다.
resource "aws_iam_role_policy" "control_plane" {
  role = aws_iam_role.node["control-plane"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow", Action = ["ec2:DescribeInstances", "ec2:DescribeRegions", "ec2:DescribeAvailabilityZones", "ec2:DescribeVpcs", "ec2:DescribeSubnets", "ec2:DescribeSecurityGroups", "ec2:DescribeRouteTables", "ec2:DescribeInstanceTopology"], Resource = "*"
      },
      {
        Effect = "Allow", Action = ["ssm:PutParameter"], Resource = "arn:${local.partition}:ssm:${var.region}:${var.config.account_id}:parameter/${local.name}/join/*"
      },
      {
        Effect = "Allow", Action = ["s3:PutObject"], Resource = "${aws_s3_bucket.storage["etcd-backup"].arn}/*"
      }

    ]
    }
  )
}

resource "aws_kms_key" "vault" {
  description             = "${local.name} Vault auto-unseal"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

resource "aws_kms_alias" "vault" {
  name          = "alias/${local.name}-vault"
  target_key_id = aws_kms_key.vault.key_id
}

# kubeadm에는 EKS OIDC issuer가 없습니다. 실제 issuer/JWKS를 준비한 뒤 입력해야 합니다.
resource "aws_iam_openid_connect_provider" "cluster" {
  count           = var.config.oidc == null ? 0 : 1
  url             = var.config.oidc.url
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = length(var.config.oidc.thumbprints) == 0 ? null : var.config.oidc.thumbprints
}

locals {
  pod_subjects = {
    ebs_csi    = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
    autoscaler = "system:serviceaccount:kube-system:cluster-autoscaler"
    loki       = "system:serviceaccount:monitoring:loki"
    vault      = "system:serviceaccount:vault:vault"
  }
}

resource "aws_iam_role" "pod" {
  for_each = var.config.oidc == null ? {
  } : local.pod_subjects
  name = "${local.name}-${each.key}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.cluster[0].arn
      }

      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${trimprefix(var.config.oidc.url, "https://")}:aud" = "sts.amazonaws.com"
          "${trimprefix(var.config.oidc.url, "https://")}:sub" = each.value
        }
      }
      }
    ]
    }
  )
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  count      = var.config.oidc == null ? 0 : 1
  role       = aws_iam_role.pod["ebs_csi"].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_iam_role_policy" "loki" {
  count = var.config.oidc == null ? 0 : 1
  role  = aws_iam_role.pod["loki"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow", Action = ["s3:ListBucket"], Resource = aws_s3_bucket.storage["loki"].arn
      },
      {
        Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], Resource = "${aws_s3_bucket.storage["loki"].arn}/*"
      }

    ]
    }
  )
}

resource "aws_iam_role_policy" "autoscaler" {
  count = var.config.oidc == null ? 0 : 1
  role  = aws_iam_role.pod["autoscaler"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow", Action = ["autoscaling:DescribeAutoScalingGroups", "autoscaling:DescribeAutoScalingInstances", "autoscaling:DescribeLaunchConfigurations", "autoscaling:DescribeScalingActivities", "autoscaling:DescribeTags", "ec2:DescribeImages", "ec2:DescribeInstanceTypes", "ec2:DescribeLaunchTemplateVersions", "ec2:GetInstanceTypesFromInstanceRequirements"], Resource = "*"
      },
      {
        Effect = "Allow", Action = ["autoscaling:SetDesiredCapacity", "autoscaling:TerminateInstanceInAutoScalingGroup"], Resource = [for asg in aws_autoscaling_group.worker : asg.arn]
      }

    ]
    }
  )
}


resource "aws_iam_role_policy" "vault_pod" {
  count = var.config.oidc == null ? 0 : 1
  role  = aws_iam_role.pod["vault"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey"], Resource = aws_kms_key.vault.arn },
      { Effect = "Allow", Action = ["s3:PutObject"], Resource = "${aws_s3_bucket.storage["vault-backup"].arn}/*" }
    ]
  })
}
