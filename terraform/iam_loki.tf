# =============================================================================
# LOKI PRODUCTION STORAGE AND PERMISSIONS
# =============================================================================

# 1. S3 Bucket for Log Chunks and Indexes
resource "aws_s3_bucket" "loki_storage" {
  bucket        = "${local.cluster_name}-loki-logs"
  force_destroy = true # Set to false for actual long-term production
}

# 2. IAM Role for Service Accounts (IRSA)
module "loki_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${local.cluster_name}-loki-s3-role"

  # Trust Relationship using the OIDC Provider from your EKS module
  oidc_providers = {
    main = {
      provider_arn               = module.retail_app_eks.oidc_provider_arn
      namespace_service_accounts = ["monitoring:loki-stack"]
    }
  }

  role_policy_arns = {
    policy = aws_iam_policy.loki_s3_access.arn
  }
}

# 3. Policy allowing Loki to Read/Write to S3
resource "aws_iam_policy" "loki_s3_access" {
  name        = "${local.cluster_name}-loki-s3-policy"
  description = "Allows Loki pods to manage log objects in S3"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket",
          "s3:DeleteObject"
        ]
        Effect   = "Allow"
        Resource = [
          aws_s3_bucket.loki_storage.arn,
          "${aws_s3_bucket.loki_storage.arn}/*"
        ]
      }
    ]
  })
}