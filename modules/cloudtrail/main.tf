variable "data_kms_arn" { type = string }

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "trail" {
  bucket = "quill-cloudtrail"
}

resource "aws_s3_bucket_object_lock_configuration" "trail" {
  bucket = aws_s3_bucket.trail.id
  rule {
    default_retention {
      mode = "COMPLIANCE"
      days = 90
    }
  }
}

data "aws_iam_policy_document" "trail_bucket" {
  statement {
    sid     = "AWSCloudTrailAclCheck"
    effect  = "Allow"
    actions = ["s3:GetBucketAcl"]
    principals { type = "Service" identifiers = ["cloudtrail.amazonaws.com"] }
    resources = [aws_s3_bucket.trail.arn]
  }
  statement {
    sid     = "AWSCloudTrailWrite"
    effect  = "Allow"
    actions = ["s3:PutObject"]
    principals { type = "Service" identifiers = ["cloudtrail.amazonaws.com"] }
    resources = ["${aws_s3_bucket.trail.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }
}

resource "aws_s3_bucket_policy" "trail" {
  bucket = aws_s3_bucket.trail.id
  policy = data.aws_iam_policy_document.trail_bucket.json
}

resource "aws_cloudtrail" "main" {
  name                          = "quill"
  s3_bucket_name                = aws_s3_bucket.trail.id
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true
  kms_key_id                    = var.data_kms_arn

  depends_on = [aws_s3_bucket_policy.trail]
}

output "trail_bucket_arn" { value = aws_s3_bucket.trail.arn }
output "trail_arn"        { value = aws_cloudtrail.main.arn }
