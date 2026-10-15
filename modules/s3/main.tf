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

# ---- trust mirror CORS ----
# The trust records are public, credential-free JSON and text. Browsers read
# them cross-origin, and the JS SDK's policyFromTrustRelease() sends a
# user-agent header, which is not CORS-safelisted, so a browser that honours
# it sends a preflight first. Without this block, a GET carries no
# Access-Control-Allow-Origin and OPTIONS gets 403 from CloudFront. That
# leaves the mirror unreadable from a page.
#
# The response headers policy adds the headers to GET/HEAD responses. The
# viewer-request function answers OPTIONS at the edge: the policy only adds
# headers, so a forwarded OPTIONS would keep the S3 website origin's error
# status. Both read these locals. No credentials: nothing here is cookie- or
# auth-scoped.
locals {
  trust_cors_allow_origin  = "*"
  trust_cors_allow_methods = ["GET", "HEAD", "OPTIONS"]
  trust_cors_allow_headers = "*"
  trust_cors_max_age_sec   = 600
}

resource "aws_cloudfront_response_headers_policy" "trust_cors" {
  name    = "trust-mirror-cors"
  comment = "Public, credential-free CORS for the static trust mirror"

  cors_config {
    access_control_allow_credentials = false
    access_control_max_age_sec       = local.trust_cors_max_age_sec
    origin_override                  = true

    access_control_allow_headers {
      items = [local.trust_cors_allow_headers]
    }
    access_control_allow_methods {
      items = local.trust_cors_allow_methods
    }
    access_control_allow_origins {
      items = [local.trust_cors_allow_origin]
    }
  }
}

resource "aws_cloudfront_function" "trust_preflight" {
  name    = "trust-mirror-cors-preflight"
  runtime = "cloudfront-js-2.0"
  comment = "Answer CORS preflights for the trust mirror with 204"
  publish = true
  code = templatefile("${path.module}/trust-preflight.js.tftpl", {
    allow_origin  = local.trust_cors_allow_origin
    allow_methods = join(", ", local.trust_cors_allow_methods)
    allow_headers = local.trust_cors_allow_headers
    max_age_sec   = local.trust_cors_max_age_sec
  })
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
    # OPTIONS never reaches S3: trust_preflight answers it at the edge.
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD"]
    target_origin_id           = "S3Website"
    response_headers_policy_id = aws_cloudfront_response_headers_policy.trust_cors.id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.trust_preflight.arn
    }

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
