# =============================================================================
# IAM USERS AND GROUPS FOR RBAC
# =============================================================================

# =============================================================================
# DEVELOPER TEAM
# =============================================================================

resource "aws_iam_user" "developers" {
  for_each = toset(local.developer_users)
  name     = each.value
  tags     = merge(local.common_tags, { Team = "developer" })
}

resource "aws_iam_group" "developers" {
  name = "${local.cluster_name}-developers"
}

resource "aws_iam_group_membership" "developers" {
  name  = "${local.cluster_name}-developers-membership"
  group = aws_iam_group.developers.name
  users = [for u in aws_iam_user.developers : u.name]
}

# Minimum IAM policy — only connect to EKS, nothing else
resource "aws_iam_policy" "developer_eks_access" {
  name        = "${local.cluster_name}-developer-eks-access"
  description = "Allows developers to connect to EKS cluster only"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EKSConnect"
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:ListClusters"
        ]
        Resource = "arn:aws:eks:${var.aws_region}:${data.aws_caller_identity.current.account_id}:cluster/${local.cluster_name}"
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_group_policy_attachment" "developer_eks_access" {
  group      = aws_iam_group.developers.name
  policy_arn = aws_iam_policy.developer_eks_access.arn
}

# =============================================================================
# DEVOPS TEAM
# =============================================================================

resource "aws_iam_user" "devops" {
  for_each = toset(local.devops_users)
  name     = each.value
  tags     = merge(local.common_tags, { Team = "devops" })
}

resource "aws_iam_group" "devops" {
  name = "${local.cluster_name}-devops"
}

resource "aws_iam_group_membership" "devops" {
  name  = "${local.cluster_name}-devops-membership"
  group = aws_iam_group.devops.name
  users = [for u in aws_iam_user.devops : u.name]
}

# DevOps gets EKS access + ECR access
resource "aws_iam_policy" "devops_eks_access" {
  name        = "${local.cluster_name}-devops-eks-access"
  description = "Allows devops to connect to EKS and manage ECR"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EKSConnect"
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:ListClusters",
          "eks:ListNodegroups",
          "eks:DescribeNodegroup"
        ]
        Resource = "arn:aws:eks:${var.aws_region}:${data.aws_caller_identity.current.account_id}:cluster/${local.cluster_name}"
      },
      {
        Sid    = "ECRAccess"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:DescribeRepositories",
          "ecr:ListImages",
          "ecr:DescribeImages"
        ]
        Resource = "*"
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_group_policy_attachment" "devops_eks_access" {
  group      = aws_iam_group.devops.name
  policy_arn = aws_iam_policy.devops_eks_access.arn
}

# =============================================================================
# SRE TEAM
# =============================================================================

resource "aws_iam_user" "sre" {
  for_each = toset(local.sre_users)
  name     = each.value
  tags     = merge(local.common_tags, { Team = "sre" })
}

resource "aws_iam_group" "sre" {
  name = "${local.cluster_name}-sre"
}

resource "aws_iam_group_membership" "sre" {
  name  = "${local.cluster_name}-sre-membership"
  group = aws_iam_group.sre.name
  users = [for u in aws_iam_user.sre : u.name]
}

# SRE gets EKS + CloudWatch logs access
resource "aws_iam_policy" "sre_eks_access" {
  name        = "${local.cluster_name}-sre-eks-access"
  description = "Allows SRE to connect to EKS and read CloudWatch logs"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EKSConnect"
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:ListClusters",
          "eks:ListNodegroups",
          "eks:DescribeNodegroup",
          "eks:AccessKubernetesApi"
        ]
        Resource = "arn:aws:eks:${var.aws_region}:${data.aws_caller_identity.current.account_id}:cluster/${local.cluster_name}"
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
          "logs:GetLogEvents"
        ]
        Resource = "*"
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_group_policy_attachment" "sre_eks_access" {
  group      = aws_iam_group.sre.name
  policy_arn = aws_iam_policy.sre_eks_access.arn
}

# =============================================================================
# OUTPUTS
# =============================================================================

output "developer_users" {
  description = "Developer IAM user ARNs"
  value       = { for k, v in aws_iam_user.developers : k => v.arn }
}

output "devops_users" {
  description = "DevOps IAM user ARNs"
  value       = { for k, v in aws_iam_user.devops : k => v.arn }
}

output "sre_users" {
  description = "SRE IAM user ARNs"
  value       = { for k, v in aws_iam_user.sre : k => v.arn }
}
