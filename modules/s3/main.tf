variable "data_kms_arn" { type = string }
variable "domain" { type = string }
variable "trust_sub" { type = string }

data "aws_caller_identity" "current" {}

# ---- device-keys bucket: holds the KMS-encrypted sealed blob ----
resource "aws_s3_bucket" "device_keys" {
  bucket = "quill-device-keys-${data.aws_caller_identity.current.account_id}"
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
  bucket = "${var.trust_sub}.${var.domain}"
}

resource "aws_s3_bucket_website_configuration" "trust" {
  bucket = aws_s3_bucket.trust.id
  index_document { suffix = "index.html" }
}

resource "aws_acm_certificate" "trust" {
  domain_name       = "${var.trust_sub}.${var.domain}"
  validation_method = "DNS"
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate_validation" "trust" {
  certificate_arn = aws_acm_certificate.trust.arn
}

resource "aws_cloudfront_distribution" "trust" {
  origin {
    domain_name = aws_s3_bucket_website_configuration.trust.website_endpoint
    origin_id   = "S3Website"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"

  aliases = ["${var.trust_sub}.${var.domain}"]

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "S3Website"

    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.trust.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
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
  bucket = "quill-alb-access-logs-${data.aws_caller_identity.current.account_id}"
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

output "device_keys_bucket_arn" { value = aws_s3_bucket.device_keys.arn }
output "device_keys_bucket_name" { value = aws_s3_bucket.device_keys.id }
output "trust_bucket_arn" { value = aws_s3_bucket.trust.arn }
output "trust_bucket_website_endpoint" { value = aws_s3_bucket_website_configuration.trust.website_endpoint }
output "trust_cloudfront_domain" { value = aws_cloudfront_distribution.trust.domain_name }
output "trust_acm_validation_records" {
  value = [
    for o in aws_acm_certificate.trust.domain_validation_options :
    {
      name  = o.resource_record_name
      type  = o.resource_record_type
      value = o.resource_record_value
    }
  ]
}
output "alb_logs_bucket_arn" { value = aws_s3_bucket.alb_logs.arn }
output "alb_logs_bucket_id" { value = aws_s3_bucket.alb_logs.id }
