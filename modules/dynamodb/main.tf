variable "data_kms_arn" { type = string }

resource "aws_dynamodb_table" "usage" {
  name         = "quill_usage"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "device_id"
  range_key    = "day"

  attribute {
    name = "device_id"
    type = "S"
  }
  attribute {
    name = "day"
    type = "S"
  }

  ttl {
    attribute_name = "ttl_epoch"
    enabled        = true
  }

  point_in_time_recovery { enabled = true }

  server_side_encryption {
    enabled     = true
    kms_key_arn = var.data_kms_arn
  }

  tags = { Name = "quill_usage" }
}

output "usage_table_arn"  { value = aws_dynamodb_table.usage.arn }
output "usage_table_name" { value = aws_dynamodb_table.usage.name }
