variable "data_kms_arn" { type = string }

# CIS wants CloudTrail retained for at least a year. 365 matches live.
variable "log_retention_days" {
  type    = number
  default = 365
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_s3_bucket" "trail" {
  bucket = "quill-cloudtrail-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_versioning" "trail" {
  bucket = aws_s3_bucket.trail.id
  versioning_configuration {
    status = "Enabled"
  }
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
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    resources = [aws_s3_bucket.trail.arn]
  }
  statement {
    sid     = "AWSCloudTrailWrite"
    effect  = "Allow"
    actions = ["s3:PutObject"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
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

# ---------------------------------------------------------------------------
# CloudTrail -> CloudWatch Logs.
# ---------------------------------------------------------------------------
# This delivery existed in the account from 2026-08-15 but not in this module,
# and the gap was not benign. Because `aws_cloudtrail` is a managed resource,
# an attribute absent from config is an attribute Terraform drives to null, so
# `terraform plan` on 2026-08-17 read:
#
#   # module.cloudtrail.aws_cloudtrail.main will be updated in-place
#     - cloud_watch_logs_group_arn = ".../log-group:/aws/cloudtrail/quill:*" -> null
#     - cloud_watch_logs_role_arn  = ".../role/CloudTrail-CloudWatchLogs-quill" -> null
#
# An apply — including one run as a CORRECTIVE action — would therefore have
# removed the log stream that the two CIS metric filters read. The alarms
# CIS-RootAccountUsage and CIS-UnauthorizedAPICalls do not fail loudly when
# that happens: their metrics simply stop receiving datapoints, and with
# treat_missing_data = notBreaching they sit in OK indefinitely while root
# logins and AccessDenied storms go unobserved. Delivery to S3 keeps working,
# so every dashboard still reports "CloudTrail: enabled".
#
# That is the worst failure shape a detective control can have, so the delivery
# is declared here rather than left to drift back in by hand.

resource "aws_cloudwatch_log_group" "trail" {
  name              = "/aws/cloudtrail/quill"
  retention_in_days = var.log_retention_days
}

data "aws_iam_policy_document" "trail_cw_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    # SourceArn pins the trail that may assume this role. CloudTrail populates
    # it, so a hard condition is correct here — unlike an EC2 instance-profile
    # role, where the key is absent and a hard equality fails closed.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = ["arn:aws:cloudtrail:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:trail/quill"]
    }
  }
}

data "aws_iam_policy_document" "trail_cw_write" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.trail.arn}:*"]
  }
}

resource "aws_iam_role" "trail_cw" {
  name               = "CloudTrail-CloudWatchLogs-quill"
  assume_role_policy = data.aws_iam_policy_document.trail_cw_assume.json
}

resource "aws_iam_role_policy" "trail_cw" {
  name   = "WriteTrailEvents"
  role   = aws_iam_role.trail_cw.id
  policy = data.aws_iam_policy_document.trail_cw_write.json
}

resource "aws_cloudtrail" "main" {
  name                          = "quill"
  s3_bucket_name                = aws_s3_bucket.trail.id
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true
  kms_key_id                    = var.data_kms_arn

  # The two lines whose absence was the finding.
  cloud_watch_logs_group_arn = "${aws_cloudwatch_log_group.trail.arn}:*"
  cloud_watch_logs_role_arn  = aws_iam_role.trail_cw.arn

  depends_on = [aws_s3_bucket_policy.trail, aws_iam_role_policy.trail_cw]
}

output "trail_bucket_arn" { value = aws_s3_bucket.trail.arn }
output "trail_arn" { value = aws_cloudtrail.main.arn }
