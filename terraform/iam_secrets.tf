# =============================================================================
# IAM ROLE FOR SECRETS ACCESS (IRSA)
# =============================================================================

# Policy allowing pods to read secrets and use KMS key
resource "aws_iam_policy" "secrets_access" {
  name        = "${local.cluster_name}-secrets-access"
  description = "Allow retail-store pods to read Secrets Manager secrets via KMS"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SecretsManagerRead"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = [
          aws_secretsmanager_secret.cart.arn,
          aws_secretsmanager_secret.orders.arn,
          aws_secretsmanager_secret.checkout.arn,
        ]
      },
      {
        Sid    = "KMSDecrypt"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:DescribeKey"
        ]
        Resource = aws_kms_key.secrets.arn
      }
    ]
  })

  tags = local.common_tags
}

# IRSA role - bound to retail-store namespace service accounts
module "secrets_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${local.cluster_name}-secrets-irsa"

  oidc_providers = {
    main = {
      provider_arn               = module.retail_app_eks.oidc_provider_arn
      namespace_service_accounts = [
        "retail-store:cart",
        "retail-store:orders",
        "retail-store:checkout",
      ]
    }
  }

  role_policy_arns = {
    secrets = aws_iam_policy.secrets_access.arn
  }

  tags = local.common_tags
}
