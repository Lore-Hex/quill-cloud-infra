variable "subscription_id" {
  description = "Azure subscription holding the production deployment."
  type        = string
}

variable "resource_group_name" {
  type    = string
  default = "tr-azure"
}

variable "location" {
  description = "Must be the control plane's region: the drain reads that cloud's Postgres and writes the node, so a cross-region hop is latency on the settle path for no benefit."
  type        = string
  default     = "uaenorth"
}

variable "vnet_name" {
  type    = string
  default = "vnet-prod"
}

variable "vnet_cidr" {
  description = "Allowed to reach ClickHouse on 8123/9000. Nothing outside it can."
  type        = string
  default     = "10.61.0.0/16"
}

variable "clickhouse_subnet_prefix" {
  description = "Must not overlap the Container Apps subnet (delegated, cannot host a VM) or the private-endpoint subnet."
  type        = string
  default     = "10.61.3.0/24"
}

variable "key_vault_id" {
  description = "Vault holding the ClickHouse password. No default: naming the vault that holds every provider secret should be a deliberate act in a tfvars file, not something inherited silently."
  type        = string
}

variable "admin_ssh_public_key" {
  description = "Public half only. Break-glass from inside the VNet; the normal path is `az vm run-command` through the VM agent."
  type        = string
}

variable "clickhouse_custom_data_base64" {
  description = "Base64 cloud-config for the node. See the module's variable docs for the YAML trap it must avoid."
  type        = string
}
