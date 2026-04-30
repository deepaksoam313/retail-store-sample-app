# =============================================================================
# KMS KEY FOR SECRETS ENCRYPTION
# =============================================================================

resource "aws_kms_key" "secrets" {
  description             = "KMS key for retail-store secrets encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = local.common_tags
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/${local.cluster_name}-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}

# =============================================================================
# SECRETS MANAGER - PER SERVICE
# =============================================================================

# Cart Service - PostgreSQL config
# NOTE: Secret value must be created by admin BEFORE terraform apply
# aws secretsmanager create-secret \
#   --name "<cluster-name>/cart" \
#   --secret-string '{"POSTGRES_PASSWORD":"<your-password>","POSTGRES_USERNAME":"cart_user","POSTGRES_DB":"cartdb"}'
resource "aws_secretsmanager_secret" "cart" {
  name                    = "${local.cluster_name}/cart"
  description             = "Cart service configuration — value set by admin"
  kms_key_id              = aws_kms_key.secrets.arn
  recovery_window_in_days = 7
  tags                    = local.common_tags
}
# NOTE: No secret_version here — admin sets the value manually
# Terraform only creates the secret container, not the value

# Orders Service - PostgreSQL config
resource "aws_secretsmanager_secret" "orders" {
  name                    = "${local.cluster_name}/orders"
  description             = "Orders service configuration"
  kms_key_id              = aws_kms_key.secrets.arn
  recovery_window_in_days = 7
  tags                    = local.common_tags
}

resource "aws_secretsmanager_secret_version" "orders" {
  secret_id = aws_secretsmanager_secret.orders.id
  secret_string = jsonencode({
    RETAIL_CHECKOUT_PERSISTENCE_PROVIDER           = "postgres"
    RETAIL_ORDERS_PERSISTENCE_POSTGRES_ENDPOINT    = "orders-db.retail-store.svc.cluster.local:5432"
    RETAIL_ORDERS_PERSISTENCE_POSTGRES_NAME        = "orders"
    RETAIL_ORDERS_PERSISTENCE_POSTGRES_USERNAME    = "orders_user"
    RETAIL_ORDERS_PERSISTENCE_POSTGRES_PASSWORD    = random_password.orders_db.result
    RETAIL_ORDERS_MESSAGING_PROVIDER               = "in-memory"
  })
}

# Checkout Service
resource "aws_secretsmanager_secret" "checkout" {
  name                    = "${local.cluster_name}/checkout"
  description             = "Checkout service configuration"
  kms_key_id              = aws_kms_key.secrets.arn
  recovery_window_in_days = 7
  tags                    = local.common_tags
}

resource "aws_secretsmanager_secret_version" "checkout" {
  secret_id = aws_secretsmanager_secret.checkout.id
  secret_string = jsonencode({
    PORT = "8080"
  })
}

# =============================================================================
# RANDOM PASSWORDS
# =============================================================================

resource "random_password" "orders_db" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}
