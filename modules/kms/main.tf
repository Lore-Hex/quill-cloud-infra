# Two CMKs:
#   1) device-keys-cmk — used to encrypt/decrypt the sealed device-key blob.
#      Decrypt is gated by kms:RecipientAttestation:PCR0 (the published
#      enclave measurement). This is the heart of the trust story.
#   2) data-cmk — used for DynamoDB table SSE, S3 bucket SSE, and
#      CloudWatch Logs encryption. Standard policy.

variable "parent_role_arn" { type = string }
variable "published_pcr0_hex" { type = string }

data "aws_caller_identity" "current" {}

# ------- device-keys-cmk: attestation-locked decrypt --------
resource "aws_kms_key" "device_keys" {
  description             = "Quill device-key blob: decrypt only by attested enclave"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.device_keys_policy.json
}

resource "aws_kms_alias" "device_keys" {
  name          = "alias/quill-device-keys"
  target_key_id = aws_kms_key.device_keys.key_id
}

data "aws_iam_policy_document" "device_keys_policy" {
  # 1) Account root — for break-glass, key admin, key rotation.
  statement {
    sid    = "RootKeyAdmin"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
    actions   = ["kms:*"]
    resources = ["*"]
  }

  # 2) Operator (admin role assumed via OIDC) — Encrypt only, not Decrypt.
  #    Operator can re-seal the blob with new keys but CANNOT read the
  #    current contents. (Decrypt is reserved for the attested enclave.)
  statement {
    sid    = "OperatorMayEncryptOnly"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/quill-deploy"]
    }
    actions   = ["kms:Encrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = ["*"]
  }

  # 3) Parent host role — Decrypt allowed only when the request comes from
  #    a Nitro Enclave whose PCR0 matches the published measurement.
  statement {
    sid    = "AttestedEnclaveDecryptOnly"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = [var.parent_role_arn]
    }
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    # When published_pcr0_hex is empty (bootstrap), the condition is omitted —
    # which means the role can Decrypt freely. Set this var BEFORE accepting
    # any production traffic.
    dynamic "condition" {
      for_each = var.published_pcr0_hex == "" ? [] : [1]
      content {
        test     = "StringEqualsIgnoreCase"
        variable = "kms:RecipientAttestation:PCR0"
        values   = [var.published_pcr0_hex]
      }
    }
  }
}

# ------- data-cmk: standard encryption-at-rest -------------
resource "aws_kms_key" "data" {
  description             = "Quill data-at-rest CMK (DDB, S3, CloudWatch Logs, CloudTrail)"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.data_policy.json
}

resource "aws_kms_alias" "data" {
  name          = "alias/quill-data"
  target_key_id = aws_kms_key.data.key_id
}

data "aws_iam_policy_document" "data_policy" {
  # 1) Root user full access
  statement {
    sid    = "RootKeyAdmin"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
    actions   = ["kms:*"]
    resources = ["*"]
  }

  # 2) Deploy role access
  statement {
    sid    = "OperatorAccess"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/quill-deploy"]
    }
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = ["*"]
  }

  # 3) Parent host access
  statement {
    sid    = "ParentHostAccess"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = [var.parent_role_arn]
    }
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = ["*"]
  }

  # 4) CloudTrail access
  statement {
    sid    = "CloudTrailAccess"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    actions   = ["kms:GenerateDataKey*", "kms:Decrypt", "kms:DescribeKey"]
    resources = ["*"]
  }
}

output "device_keys_cmk_arn" { value = aws_kms_key.device_keys.arn }
output "device_keys_alias" { value = aws_kms_alias.device_keys.name }
output "data_cmk_arn" { value = aws_kms_key.data.arn }
