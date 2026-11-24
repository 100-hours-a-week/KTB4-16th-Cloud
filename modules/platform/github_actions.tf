# GitHub Actions가 장기 액세스 키 없이 OIDC 토큰으로 ECR에 이미지를 push합니다.
# 저장소마다 역할을 따로 두어, 한 저장소의 워크플로가 다른 서비스 이미지를 덮어쓸 수 없게 합니다.
locals {
  github_oidc_host = "token.actions.githubusercontent.com"
  github_ecr_push  = var.config.github_actions == null ? {} : var.config.github_actions.ecr_push_repositories
  # 저장소별로 허용할 sub 목록. 이름 형식은 항상, 숫자 ID 형식은 ID가 주어진 저장소만 넣습니다.
  github_ecr_push_subs = {
    for k, repo in local.github_ecr_push : k => concat(
      ["repo:${repo}:ref:refs/heads/${var.config.github_actions.branch}"],
      contains(keys(var.config.github_actions.repository_ids), k) ? [format(
        "repo:%s@%s/%s@%s:ref:refs/heads/%s",
        split("/", repo)[0], var.config.github_actions.owner_id,
        split("/", repo)[1], var.config.github_actions.repository_ids[k],
        var.config.github_actions.branch,
      )] : []
    )
  }
}

resource "aws_iam_openid_connect_provider" "github" {
  count          = var.config.github_actions == null ? 0 : 1
  url            = "https://${local.github_oidc_host}"
  client_id_list = ["sts.amazonaws.com"]
  # IAM이 GitHub OIDC는 신뢰된 루트 CA로 검증하므로 thumbprint를 고정하지 않습니다.
}

resource "aws_iam_role" "github_ecr_push" {
  for_each = local.github_ecr_push
  name     = "${local.name}-gha-ecr-push-${each.key}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github[0].arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.github_oidc_host}:aud" = "sts.amazonaws.com"
          "${local.github_oidc_host}:sub" = local.github_ecr_push_subs[each.key]
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_ecr_push" {
  for_each = local.github_ecr_push
  name     = "ecr-push"
  role     = aws_iam_role.github_ecr_push[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # docker login 토큰 발급은 저장소 단위로 제한할 수 없는 API입니다.
        Effect = "Allow", Action = "ecr:GetAuthorizationToken", Resource = "*"
      },
      {
        # docker buildx push는 레이어/매니페스트 존재 확인을 위해 pull 계열 API도 호출합니다.
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:DescribeImages",
        ]
        Resource = aws_ecr_repository.app[each.key].arn
      }
    ]
  })
}
