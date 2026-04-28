variable "data_kms_arn" { type = string }
variable "domain" { type = string }
variable "trust_sub" { type = string }

# ---- device-keys bucket: holds the KMS-encrypted sealed blob ----
resource "aws_s3_bucket" "device_keys" {
  bucket = "quill-device-keys"
}

resource "aws_s3_bucket_public_access_block" "device_keys" {
  bucket                  = aws_s3_bucket.device_keys.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "device_keys" {
  bucket = aws_s3_bucket.device_keys.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "device_keys" {
  bucket = aws_s3_bucket.device_keys.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.data_kms_arn
    }
  }
}

# ---- trust-page bucket: static HTML, S3 website hosting, public read ----
resource "aws_s3_bucket" "trust" {
  bucket = "quill-trust-page"
}

resource "aws_s3_bucket_website_configuration" "trust" {
  bucket = aws_s3_bucket.trust.id
  index_document { suffix = "index.html" }
}

resource "aws_s3_bucket_public_access_block" "trust" {
  bucket                  = aws_s3_bucket.trust.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

data "aws_iam_policy_document" "trust_public" {
  statement {
    sid     = "AllowPublicRead"
    effect  = "Allow"
    actions = ["s3:GetObject"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    resources = ["${aws_s3_bucket.trust.arn}/*"]
  }
}

resource "aws_s3_bucket_policy" "trust" {
  bucket     = aws_s3_bucket.trust.id
  policy     = data.aws_iam_policy_document.trust_public.json
  depends_on = [aws_s3_bucket_public_access_block.trust]
}

# ---- ALB access logs bucket: short retention ----
resource "aws_s3_bucket" "alb_logs" {
  bucket = "quill-alb-access-logs"
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    id     = "expire-after-1-day"
    status = "Enabled"
    filter {}
    expiration { days = 1 }
  }
}

output "device_keys_bucket_arn"        { value = aws_s3_bucket.device_keys.arn }
output "device_keys_bucket_name"       { value = aws_s3_bucket.device_keys.id }
output "trust_bucket_arn"              { value = aws_s3_bucket.trust.arn }
output "trust_bucket_website_endpoint" { value = aws_s3_bucket_website_configuration.trust.website_endpoint }
output "alb_logs_bucket_arn"           { value = aws_s3_bucket.alb_logs.arn }
output "alb_logs_bucket_id"            { value = aws_s3_bucket.alb_logs.id }
