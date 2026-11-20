// Bucket policies for the two Terraform state buckets, quill-tf-state-prod
// (us-east-1, envs/prod) and quill-tf-state-eu (eu-west-3, envs/aws-eu-prod).
//
// WHY
//
// State files carry secrets. Before this root, the buckets blocked public
// access but had no bucket policy, so any identity in the account whose IAM
// policy allows S3 could read state: on 2026-11-20 the policy simulator found
// the GitHub Actions deploy role (PowerUserAccess) could, beside the human
// administrator. Nothing in CI needs state: this repository's CI runs
// `terraform init -backend=false`, and the CI-applied quill-router infra keeps
// its state in GCS.
//
// WHAT
//
// Each bucket gets two Deny statements:
//   1. Any request not made over TLS.
//   2. Every S3 action except reading bucket configuration, for every
//      principal other than the administrator who applies this root and the
//      account root user. That covers reading, writing, listing and deleting
//      state, and changing the bucket policy, versioning, lifecycle,
//      replication, encryption or public access block. Configuration reads
//      stay open so audit tooling (the SOC 2 audit role, Access Analyzer)
//      keeps working.
//
// WHO APPLIES IT
//
// The administrator, from their own credentials: the allowed identity is the
// one running `terraform apply` (data.aws_caller_identity), so no name is
// written here. It must be an IAM user, because a role session's ARN differs
// from the aws:PrincipalArn S3 evaluates; the precondition refuses anything
// else. CI must never apply this root: an identity that can rewrite the policy
// could lift it.
//
// If the policy ever locks out the administrator, the account root user can
// always read, replace or delete a bucket policy, even one that denies it.
//
//   cd envs/tfstate-guard
//   terraform init
//   terraform plan    # two aws_s3_bucket_policy to add
//   terraform apply
//
// This root's own state sits in quill-tf-state-prod under its own key, so the
// policy guards it too.
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    bucket       = "quill-tf-state-prod"
    key          = "envs/tfstate-guard/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

locals {
  account_id = "330422590279"

  state_buckets = {
    prod = { name = "quill-tf-state-prod", region = "us-east-1" }
    eu   = { name = "quill-tf-state-eu", region = "eu-west-3" }
  }

  // Bucket configuration reads that stay open to the account's other
  // identities. Everything else is denied to them.
  config_reads = [
    "s3:GetBucket*",
    "s3:GetEncryptionConfiguration",
    "s3:GetLifecycleConfiguration",
    "s3:GetReplicationConfiguration",
  ]

  state_admins = [
    data.aws_caller_identity.current.arn,
    "arn:aws:iam::${local.account_id}:root",
  ]
}

provider "aws" {
  region              = local.state_buckets.prod.region
  allowed_account_ids = [local.account_id]
}

provider "aws" {
  alias               = "eu"
  region              = local.state_buckets.eu.region
  allowed_account_ids = [local.account_id]
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "state" {
  for_each = local.state_buckets

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = ["arn:aws:s3:::${each.value.name}", "arn:aws:s3:::${each.value.name}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid         = "StateOnlyForAdministrators"
    effect      = "Deny"
    not_actions = local.config_reads
    resources   = ["arn:aws:s3:::${each.value.name}", "arn:aws:s3:::${each.value.name}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "StringNotEquals"
      variable = "aws:PrincipalArn"
      values   = local.state_admins
    }
  }
}

resource "aws_s3_bucket_policy" "prod" {
  bucket = local.state_buckets.prod.name
  policy = data.aws_iam_policy_document.state["prod"].json

  lifecycle {
    precondition {
      condition     = can(regex("^arn:aws:iam::${local.account_id}:user/[A-Za-z0-9+=,.@_/-]+$", data.aws_caller_identity.current.arn))
      error_message = "Apply this root as the administrator's IAM user, not a role or another account: the policy allows only the applying identity."
    }
  }
}

resource "aws_s3_bucket_policy" "eu" {
  provider = aws.eu
  bucket   = local.state_buckets.eu.name
  policy   = data.aws_iam_policy_document.state["eu"].json

  lifecycle {
    precondition {
      condition     = can(regex("^arn:aws:iam::${local.account_id}:user/[A-Za-z0-9+=,.@_/-]+$", data.aws_caller_identity.current.arn))
      error_message = "Apply this root as the administrator's IAM user, not a role or another account: the policy allows only the applying identity."
    }
  }
}
