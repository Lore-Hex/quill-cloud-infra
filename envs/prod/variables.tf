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
  description = "Published PCR0 of the deployed enclave: 96 lowercase hex characters (SHA-384). Gates device-keys Decrypt via kms:RecipientAttestation:PCR0. Leaving it empty fails the plan unless allow_unattested_bootstrap = true."
  type        = string
  default     = ""
  sensitive   = false
}

variable "allow_unattested_bootstrap" {
  description = "Deliberate bootstrap only: permits an empty published_pcr0_hex, which removes the PCR0 condition so the parent host role can Decrypt device keys without attestation. Never set it while production traffic is served."
  type        = bool
  default     = false
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
