# ECR repository for the parent + enclave images, plus an AWS Signer
# profile for the eventual signed-image trust path.

resource "aws_ecr_repository" "proxy" {
  name                 = "quill-cloud-proxy"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_signer_signing_profile" "container" {
  platform_id = "Notation-OCI-SHA384-ECDSA"
  name        = "quill_container_signer"

  signature_validity_period {
    value = 12
    type  = "MONTHS"
  }
}

output "repo_arn" { value = aws_ecr_repository.proxy.arn }
output "repo_url" { value = aws_ecr_repository.proxy.repository_url }
output "signer_profile_name" { value = aws_signer_signing_profile.container.name }
