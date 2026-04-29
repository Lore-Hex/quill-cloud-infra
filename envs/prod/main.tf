# Top-level wiring. Each module owns its own subset of resources; this
# file only passes outputs between them.

module "network" {
  source = "../../modules/network"
  region = var.region
}

module "kms" {
  source             = "../../modules/kms"
  parent_role_arn    = module.iam.parent_role_arn
  published_pcr0_hex = var.published_pcr0_hex
}

module "dynamodb" {
  source       = "../../modules/dynamodb"
  data_kms_arn = module.kms.data_cmk_arn
}

module "s3" {
  source       = "../../modules/s3"
  data_kms_arn = module.kms.data_cmk_arn
  domain       = var.domain
  trust_sub    = var.trust_subdomain
}

module "ecr" {
  source = "../../modules/ecr"
}

module "iam" {
  source                 = "../../modules/iam"
  region                 = var.region
  device_keys_kms_arn    = module.kms.device_keys_cmk_arn
  data_kms_arn           = module.kms.data_cmk_arn
  usage_table_arn        = module.dynamodb.usage_table_arn
  device_keys_bucket_arn = module.s3.device_keys_bucket_arn
  trust_bucket_arn       = module.s3.trust_bucket_arn
  ecr_repo_arn           = module.ecr.repo_arn
  bedrock_vpce_id        = module.network.bedrock_vpce_id
}

module "alb" {
  source         = "../../modules/alb"
  vpc_id         = module.network.vpc_id
  public_subnets = module.network.public_subnets
  domain         = var.domain
  api_sub        = var.api_subdomain
}

# NLB does TCP passthrough on :443 to the parent's TCP-pump on :8444.
# The enclave terminates TLS — AWS infrastructure never holds plaintext
# prompt content. Lives alongside the ALB; ALB now serves operator-facing
# admin/trust/health only.
module "nlb" {
  source         = "../../modules/nlb"
  vpc_id         = module.network.vpc_id
  public_subnets = module.network.public_subnets
}

module "compute" {
  source                  = "../../modules/compute"
  vpc_id                  = module.network.vpc_id
  private_subnets         = module.network.private_subnets
  parent_role_name        = module.iam.parent_role_name
  parent_instance_profile = module.iam.parent_instance_profile
  alb_target_group        = module.alb.target_group_arn
  nlb_target_group        = module.nlb.target_group_arn
  ecr_repo_url            = module.ecr.repo_url
}

module "github_oidc" {
  source       = "../../modules/github-oidc"
  github_repos = var.github_repos
}

module "cloudtrail" {
  source       = "../../modules/cloudtrail"
  data_kms_arn = module.kms.data_cmk_arn
}
