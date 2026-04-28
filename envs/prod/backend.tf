# Remote state in S3 with a DynamoDB lock table.
# Created once by hand (see README); afterwards Terraform reads/writes here.
terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }

  backend "s3" {
    bucket         = "quill-tf-state-prod"
    key            = "envs/prod/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "quill-tf-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project   = "quill-cloud"
      ManagedBy = "terraform"
      Repo      = "Lore-Hex/quill-cloud-infra"
    }
  }
}
