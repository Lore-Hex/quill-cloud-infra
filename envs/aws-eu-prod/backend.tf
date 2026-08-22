// AWS-EU's state lives beside AWS-EU, not in envs/prod's us-east-1 bucket.
//
// State is operational infrastructure too. Putting the EU layout's state in
// us-east-1 means a us-east-1 outage -- or a regional S3 endpoint problem --
// blocks every EU change, including the ones you would make to route around
// that outage. That is exactly the cross-region prerequisite this production
// slice exists to avoid, reintroduced through the back door of a state file.
//
// Keeping state in eu-west-3 also keeps the blast radius honest: this new root
// cannot corrupt envs/prod's state and envs/prod cannot lock this one.
//
// BOOTSTRAP (one-time, before the first `terraform init` here):
//
//   aws s3api create-bucket --bucket quill-tf-state-eu --region eu-west-3 \
//     --create-bucket-configuration LocationConstraint=eu-west-3
//   aws s3api put-public-access-block --bucket quill-tf-state-eu \
//     --public-access-block-configuration \
//     BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
//   aws s3api put-bucket-versioning --bucket quill-tf-state-eu \
//     --versioning-configuration Status=Enabled
//   aws s3api put-bucket-encryption --bucket quill-tf-state-eu \
//     --server-side-encryption-configuration \
//     '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
//
// Versioning is the recovery plan for an accidentally overwritten state file.
// Locking needs no DynamoDB table: Terraform >=1.10 creates a conditional S3
// lock object when use_lockfile is true.
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  backend "s3" {
    bucket       = "quill-tf-state-eu"
    key          = "envs/aws-eu-prod/terraform.tfstate"
    region       = "eu-west-3"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id]
}
