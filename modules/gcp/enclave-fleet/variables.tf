variable "project_id" {
  description = "GCP project holding the enclave fleet."
  type        = string
}

variable "network_name" {
  description = "Existing VPC containing the fleet and targeted by the public-TLS firewall."
  type        = string
}

variable "regional_migs" {
  description = "Regional MIG shells keyed by a short, stable region name. instance_template records the import-moment measured version; deploy tooling owns later rotations."
  type = map(object({
    name              = string
    region            = string
    zones             = list(string)
    target_size       = number
    instance_template = string
  }))
}

variable "service_account_id" {
  description = "Account id, without the project domain, for the workload identity shared by the enclave fleet."
  type        = string
}

variable "service_account_display_name" {
  description = "Display name of the existing workload service account."
  type        = string
}

variable "public_tls_firewall_name" {
  description = "Name of the ingress rule exposing TLS from the public Internet to the attested gateways."
  type        = string
}

variable "network_tag" {
  description = "Network tag attached by the measured templates and targeted by the public-TLS firewall."
  type        = string
}
