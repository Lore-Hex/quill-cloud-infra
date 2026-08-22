variable "resource_group_name" {
  description = "Resource group the node and its network objects live in."
  type        = string
}

variable "location" {
  description = "Azure region. Should be the control plane's region: the drain reads that cloud's Postgres and writes this node, and a cross-region hop is latency on the settle path for no benefit."
  type        = string
}

variable "vnet_name" {
  description = "VNet the control plane is already integrated into. The node joins it so the control plane can reach ClickHouse without the node being public."
  type        = string
}

variable "vnet_cidr" {
  description = "Address space allowed to reach 8123/9000. Scoped to the VNet, never Internet."
  type        = string
}

variable "subnet_name" {
  description = "Subnet created for the node. It needs its own: a Container Apps subnet is delegated to Microsoft.App/environments and cannot host a VM."
  type        = string
  default     = "snet-clickhouse"
}

variable "subnet_prefix" {
  description = "Address prefix for the node's subnet. Must not overlap the Container Apps or private-endpoint subnets."
  type        = string
}

variable "nsg_name" {
  type    = string
  default = "tr-clickhouse-nsg"
}

variable "identity_name" {
  description = "User-assigned identity the node uses to read its ClickHouse password from Key Vault at first boot. Never through custom_data, which is readable from inside the VM via IMDS."
  type        = string
  default     = "tr-clickhouse-identity"
}

variable "vm_name" {
  type = string
}

variable "vm_size" {
  description = <<-EOT
    Pick this by what ARM will actually ACCEPT, not by what the quota and SKU
    listings say. In uaenorth those three disagree: Standard_D2s_v3 has 10 vCPUs
    of quota and no listed restriction and is still refused for capacity, while
    the v5 families are offered but out of quota. Standard_D2as_v7 is accepted.
    Quota, SKU availability and capacity are three separate gates and only a
    real ARM preflight tests the third.
  EOT
  type        = string
  default     = "Standard_D2as_v7"
}

variable "os_disk_gb" {
  description = "This disk IS the analytics store."
  type        = number
  default     = 100
}

variable "os_disk_type" {
  type    = string
  default = "Premium_LRS"
}

variable "admin_username" {
  type    = string
  default = "azureuser"
}

variable "admin_ssh_public_key" {
  description = "Public half only. The node has no public IP, so this is a break-glass path from inside the VNet, not the normal way in -- that is `az vm run-command`, which goes through the VM agent."
  type        = string
}

variable "custom_data_base64" {
  description = <<-EOT
    Base64 cloud-config that installs ClickHouse, binds it to the private IP,
    fetches the password with the node's identity, and applies the schema.

    Build the commands as a write_files BLOCK SCALAR executed by runcmd, not as
    runcmd entries: runcmd entries are parsed as YAML, and any unquoted scalar
    containing ": " becomes a MAPPING. An Authorization header did exactly that
    once -- cloud-init refused to shellify a dict and the ENTIRE block died
    before one command ran, leaving a VM that provisioned cleanly with no
    ClickHouse on it.
  EOT
  type        = string
  sensitive   = false
}

variable "image_publisher" {
  type    = string
  default = "Canonical"
}

variable "image_offer" {
  type    = string
  default = "0001-com-ubuntu-server-jammy"
}

variable "image_sku" {
  type    = string
  default = "22_04-lts-gen2"
}

variable "image_version" {
  type    = string
  default = "latest"
}

variable "tags" {
  type    = map(string)
  default = {}
}
