// The Azure production layout.
//
// This root module describes what EXISTS today, so `terraform plan` is a drift
// detector rather than a wish. Everything here was provisioned before this file
// and must be IMPORTED, not created -- see README. A plan that proposes to
// create any of it means the import did not happen, and applying it would build
// a second copy of a live analytics node beside the one holding the data.
//
// WHAT IS AND IS NOT HERE
//
//   IS:      the operational-analytics ClickHouse node -- the layout half:
//            subnet, NSG, identity, NIC, machine, disk.
//
//   IS NOT:  the enclave container groups. Their CCE policy hash is a function
//            of the entire container definition, so it changes on essentially
//            every deploy, and the Key Vault release policy must be widened
//            BEFORE the group is created and narrowed only after a live
//            attestation is verified. plan/apply cannot express "widen, create,
//            verify against ground truth, narrow", and a single apply that
//            swapped that pin in one step is the documented way to end up with
//            no group and no way back. That sequencing stays in
//            quill-cloud-proxy tools/deploy-azure-aci.sh.
//
//   IS NOT:  the control plane container app, the Postgres flexible server, or
//            the vault. Those predate this file and are next; adding them means
//            importing live state, which is a change worth reviewing on its own
//            rather than bundled with a new node.

locals {
  tags = {
    Project   = "trustedrouter"
    Component = "operational-analytics"
    ManagedBy = "terraform"
  }
}

module "clickhouse" {
  source = "../../modules/azure/clickhouse-node"

  resource_group_name = var.resource_group_name
  location            = var.location
  vnet_name           = var.vnet_name
  vnet_cidr           = var.vnet_cidr
  subnet_prefix       = var.clickhouse_subnet_prefix

  nsg_name      = "tr-azure-clickhouse-nsg"
  identity_name = "tr-azure-clickhouse-identity"
  vm_name       = "tr-azure-clickhouse-1"
  nic_name      = "tr-azure-clickhouse-1VMNic"
  ipconfig_name = "ipconfigtr-azure-clickhouse-1"

  admin_ssh_public_key = var.admin_ssh_public_key
  custom_data_base64   = var.clickhouse_custom_data_base64

  tags = local.tags
}

// The node reads its ClickHouse password from Key Vault at first boot with the
// identity above. This grant is HERE, in a root module, rather than inside the
// node module: giving something access to a vault that holds every provider
// secret should be an explicit line somebody reviews, not a side effect of
// adding a machine.
//
// Read-only, one vault, secrets only. Never "Key Vault Crypto Officer", which
// would let the holder rewrite the release policy that constrains it.
resource "azurerm_role_assignment" "clickhouse_reads_its_password" {
  principal_id         = module.clickhouse.identity_principal_id
  role_definition_name = "Key Vault Secrets User"
  scope                = var.key_vault_id

  // Terraform would otherwise try to resolve the principal before it has
  // propagated through AAD, which fails intermittently on first apply.
  skip_service_principal_aad_check = true

  lifecycle {
    // This flag is client-side and create-only, so an IMPORTED assignment
    // always reads back as false and plans an in-place update -- which
    // azurerm_role_assignment does not support at all, failing the whole apply
    // with "doesn't support update".
    ignore_changes = [skip_service_principal_aad_check]
  }
}
