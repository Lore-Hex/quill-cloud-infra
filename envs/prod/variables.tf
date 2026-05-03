variable "region" {
  description = "AWS region (Bedrock Claude availability is best in us-east-1)."
  type        = string
  default     = "us-east-1"
}

variable "domain" {
  description = "Apex domain for the trust + api subdomains. Empty = ALB DNS only."
  type        = string
  default     = "lorehex.co"
}

variable "api_subdomain" {
  description = "Subdomain for the proxy. Becomes <api_subdomain>.<domain>."
  type        = string
  default     = "api.quill"
}

variable "trust_subdomain" {
  description = "Subdomain for the static trust page."
  type        = string
  default     = "trust.quill"
}

variable "published_pcr0_hex" {
  description = "Published PCR0 of the deployed enclave. Empty = bootstrap mode (KMS condition is permissive until set)."
  type        = string
  default     = ""
  sensitive   = false
}

variable "github_repos" {
  description = "Repos allowed to assume the GitHub OIDC deploy role."
  type        = list(string)
  default = [
    "Lore-Hex/quill-cloud-proxy",
    "Lore-Hex/quill-cloud-infra",
  ]
}

variable "openrouter_secret_id" {
  description = "Secrets Manager secret-id holding the OpenRouter API key. Set via TF_VAR_openrouter_secret_id when deploying the openrouter-target enclave; null otherwise."
  type        = string
  default     = null
}

variable "enclave_image_tag" {
  description = "ECR tag of the enclave image to run. 'enclave-latest' = AWS Bedrock; 'enclave-openrouter-latest' = OpenRouter ZDR."
  type        = string
  default     = "enclave-latest"
}
