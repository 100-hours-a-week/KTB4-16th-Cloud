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
