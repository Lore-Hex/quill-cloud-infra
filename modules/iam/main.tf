# Two roles:
#   - parent_host: assumed by the EC2 host running the parent process.
#       Permissions: bedrock:Invoke* via the VPC endpoint, kms:Decrypt on
#       device-keys-cmk, kms:GenerateDataKey on data-cmk, dynamodb:UpdateItem +
#       Query on quill_usage, s3:GetObject on the sealed-blob bucket,
#       s3:PutObject on the trust-page bucket (for atomic pcr0.txt updates),
#       ecr pull on the proxy repo, basic CloudWatch Logs (heartbeat group only).
#   - (github-oidc deploy role lives in its own module)

variable "region" { type = string }
variable "device_keys_kms_arn" { type = string }
variable "data_kms_arn" { type = string }
variable "usage_table_arn" { type = string }
variable "device_keys_bucket_arn" { type = string }
variable "trust_bucket_arn" { type = string }
variable "ecr_repo_arn" { type = string }
variable "bedrock_vpce_id" { type = string }

data "aws_caller_identity" "current" {}

resource "aws_iam_role" "parent_host" {
  name = "quill-parent-host"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

data "aws_iam_policy_document" "parent_host" {
  # Bedrock: only via our VPC endpoint. If creds are exfiltrated, they're
  # useless outside the VPC.
  statement {
    sid    = "BedrockInvokeViaVpce"
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceVpce"
      values   = [var.bedrock_vpce_id]
    }
  }

  # KMS: scoped to our two CMKs.
  statement {
    sid       = "KmsDecryptDeviceKeys"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = [var.device_keys_kms_arn]
  }
  statement {
    sid       = "KmsGenerateDataKey"
    effect    = "Allow"
    actions   = ["kms:GenerateDataKey", "kms:Decrypt", "kms:DescribeKey"]
    resources = [var.data_kms_arn]
  }

  # DynamoDB: only quill_usage, only UpdateItem + Query.
  statement {
    sid    = "DynamoUsageTableOnly"
    effect = "Allow"
    actions = [
      "dynamodb:UpdateItem",
      "dynamodb:Query",
      "dynamodb:DescribeTable",
    ]
    resources = [var.usage_table_arn]
  }

  # S3: read sealed blob + write trust page (single-key writes only).
  statement {
    sid       = "S3SealedBlobRead"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${var.device_keys_bucket_arn}/*"]
  }
  statement {
    sid       = "S3TrustPageWrite"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${var.trust_bucket_arn}/pcr0.txt"]
  }

  # ECR: pull our images only.
  statement {
    sid       = "EcrPullProxyOnly"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid    = "EcrPullProxyImages"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
    ]
    resources = [var.ecr_repo_arn]
  }

  # CloudWatch Logs: heartbeat group only.
  statement {
    sid    = "LogsHeartbeatGroup"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/quill/parent:*"]
  }
}

resource "aws_iam_policy" "parent_host" {
  name   = "quill-parent-host"
  policy = data.aws_iam_policy_document.parent_host.json
}

resource "aws_iam_role_policy_attachment" "parent_host" {
  role       = aws_iam_role.parent_host.name
  policy_arn = aws_iam_policy.parent_host.arn
}

resource "aws_iam_instance_profile" "parent_host" {
  name = "quill-parent-host"
  role = aws_iam_role.parent_host.name
}

output "parent_role_arn" { value = aws_iam_role.parent_host.arn }
output "parent_role_name" { value = aws_iam_role.parent_host.name }
output "parent_instance_profile" { value = aws_iam_instance_profile.parent_host.name }
