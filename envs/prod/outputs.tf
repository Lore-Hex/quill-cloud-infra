output "alb_dns_name" {
  description = "Hit this directly until Cloudflare CNAMEs are added."
  value       = module.alb.dns_name
}

output "acm_validation_records" {
  description = "Add these CNAMEs in Cloudflare for ACM cert validation (DNS-only)."
  value       = module.alb.acm_validation_records
}

output "ecr_repo_url" {
  value = module.ecr.repo_url
}

output "github_oidc_role_arn" {
  description = "Add this to GitHub repo secrets as AWS_DEPLOY_ROLE_ARN."
  value       = module.github_oidc.deploy_role_arn
}

output "trust_bucket_website_endpoint" {
  description = "Point trust.quill at this in Cloudflare (DNS-only)."
  value       = module.s3.trust_bucket_website_endpoint
}

output "device_keys_bucket" {
  description = "Pass to tools/seal-keys.py as --bucket."
  value       = module.s3.device_keys_bucket_name
}

output "device_keys_kms_alias" {
  description = "Pass to tools/seal-keys.py as --kms-key-id."
  value       = module.kms.device_keys_alias
}

output "usage_table_name" {
  value = module.dynamodb.usage_table_name
}
