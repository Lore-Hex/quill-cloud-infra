# Two CMKs:
#   1) device-keys-cmk — used to encrypt/decrypt the sealed device-key blob.
#      Decrypt is gated by kms:RecipientAttestation:PCR0 (the published
#      enclave measurement). This is the heart of the trust story.
#   2) data-cmk — used for DynamoDB table SSE, S3 bucket SSE, and
#      CloudWatch Logs encryption. Standard policy.

variable "parent_role_arn" { type = string }

variable "published_pcr0_hex" {
  description = "PCR0 of the published enclave image: 96 lowercase hex characters (SHA-384). Empty only together with allow_unattested_bootstrap."
  type        = string

  validation {
    condition     = var.published_pcr0_hex == "" || (can(regex("^[0-9a-f]{96}$", var.published_pcr0_hex)) && !can(regex("^0+$", var.published_pcr0_hex)))
    error_message = "published_pcr0_hex must be the enclave's PCR0: exactly 96 lowercase hex characters (SHA-384), not all zeros."
  }
}

variable "allow_unattested_bootstrap" {
  description = "Permit an empty published_pcr0_hex. That drops the PCR0 condition, so the parent host role can Decrypt device keys WITHOUT enclave attestation. Deliberate bootstrap only."
  type        = bool
  default     = false
}

data "aws_caller_identity" "current" {}

# ------- device-keys-cmk: attestation-locked decrypt --------
resource "aws_kms_key" "device_keys" {
  description             = "Quill device-key blob: decrypt only by attested enclave"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.device_keys_policy.json

  lifecycle {
    # An empty PCR0 used to drop the attestation condition below silently.
    # It is now a plan failure unless the bootstrap flag is set explicitly.
    precondition {
      condition     = var.published_pcr0_hex != "" || var.allow_unattested_bootstrap
      error_message = "published_pcr0_hex is empty, which would let the parent host role Decrypt device keys without enclave attestation. Set it to the published enclave PCR0, or set allow_unattested_bootstrap = true for a deliberate unattested bootstrap."
    }
  }
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

  # No operator statement. It named only the quill-deploy role, retired on
  # 2026-11-16. A key policy may name only principals that exist (KMS rejects
  # the whole document otherwise), and RootKeyAdmin already lets IAM policies
  # in this account grant Encrypt for re-sealing.

  # 2) Parent host role: Decrypt allowed only when the request comes from
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

    # Omitted only when published_pcr0_hex is empty, which the precondition on
    # aws_kms_key.device_keys allows only with allow_unattested_bootstrap. The
    # role can then Decrypt freely, so never run that way with production
    # traffic.
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

  # No deploy-role statement: it named only the quill-deploy role, retired on
  # 2026-11-16 (see the device-keys policy above).

  # 2) Parent host access
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

  # 3) CloudTrail access
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
