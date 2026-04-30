# =============================================================================
# DYNAMODB TABLE FOR CART SERVICE
# =============================================================================

resource "aws_dynamodb_table" "cart" {
  name         = "retail-store-cart-${random_string.suffix.result}"
  billing_mode = "PAY_PER_REQUEST"  # ← no capacity planning needed
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  attribute {
    name = "customerId"
    type = "S"
  }

  # GSI for querying by customerId (used by DynamoDBCartService.items())
  global_secondary_index {
    name            = "idx_global_customerId"
    hash_key        = "customerId"
    projection_type = "ALL"
  }

  # Encrypt table at rest using our KMS key
  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.secrets.arn
  }

  # Protect table from accidental deletion
  deletion_protection_enabled = true

  tags = merge(local.common_tags, {
    Service = "cart"
  })
}
