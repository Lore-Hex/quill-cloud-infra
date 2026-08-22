// One cloud's operational-analytics store: a single private ClickHouse node.
//
// settle -> tr_operational_analytics_outbox (Postgres) -> drain -> HERE
//
// Each cloud owns its own analytics, with no cross-cloud replication. That is
// the same rule the rest of the separation architecture follows, and for a
// regional deployment it is also what lets a data-residency claim survive
// contact with an auditor: operational rows about that region's traffic never
// leave it.
//
// ---------------------------------------------------------------------------
// WHAT THIS MODULE DOES NOT DO, DELIBERATELY
// ---------------------------------------------------------------------------
//   * It does not install ClickHouse. That happens in cloud-init, whose content
//     is passed in as `custom_data`, because the package install, the schema
//     and the password fetch are a boot-time sequence with retries -- not
//     declarative state Terraform can converge on. Terraform owns the LAYOUT:
//     the subnet, the NSG, the identity, the disk, the machine.
//
//   * It does not create the role assignment the node needs to read its
//     password. Terraform CAN create role assignments, and this module
//     deliberately leaves that to the caller's env so that granting access to
//     a vault holding provider secrets is an explicit line in a root module
//     somebody reviews, not a side effect of adding a node.
//
//   * It does not manage the drain. The drain is code shipped onto the node and
//     a systemd unit -- see quill-router scripts/deploy/azure_clickhouse_drain_install.sh.
//
// ---------------------------------------------------------------------------
// WHY THE NODE IS PRIVATE
// ---------------------------------------------------------------------------
// A ClickHouse with a public address is protected by a password alone. The
// control plane that reads it is already inside this VNet, so the node has no
// public IP at all and its NSG admits 8123/9000 from the VNet CIDR only.

terraform {
  required_version = ">= 1.7"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }
  }
}

resource "azurerm_network_security_group" "clickhouse" {
  name                = var.nsg_name
  location            = var.location
  resource_group_name = var.resource_group_name

  // 8123 (HTTP) and 9000 (native), from inside the VNet only. Never
  // Internet/0.0.0.0/0: see the header.
  security_rule {
    name                       = "allow-vnet-clickhouse"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    source_address_prefix      = var.vnet_cidr
    destination_port_ranges    = ["8123", "9000"]
    destination_address_prefix = "*"
  }

  tags = var.tags
}

resource "azurerm_subnet" "clickhouse" {
  name                 = var.subnet_name
  resource_group_name  = var.resource_group_name
  virtual_network_name = var.vnet_name
  address_prefixes     = [var.subnet_prefix]
}

resource "azurerm_subnet_network_security_group_association" "clickhouse" {
  subnet_id                 = azurerm_subnet.clickhouse.id
  network_security_group_id = azurerm_network_security_group.clickhouse.id
}

resource "azurerm_user_assigned_identity" "node" {
  name                = var.identity_name
  location            = var.location
  resource_group_name = var.resource_group_name

  lifecycle {
    // A replaced identity gets a NEW principal id, which silently invalidates
    // whatever grant lets the node read its own password. The node then boots,
    // finds nothing, and serves nothing.
    prevent_destroy = true
  }

  tags = var.tags
}

resource "azurerm_network_interface" "node" {
  name                = var.nic_name
  location            = var.location
  resource_group_name = var.resource_group_name

  ip_configuration {
    // The live name, minted by `az vm create` as ipconfig<vm-name>. Renaming
    // an adopted NIC's ipconfig buys nothing and churns a live interface.
    name                          = var.ipconfig_name
    subnet_id                     = azurerm_subnet.clickhouse.id
    private_ip_address_allocation = "Dynamic"
    // No public_ip_address_id. Its absence is the security property.
  }

  tags = var.tags
}

resource "azurerm_linux_virtual_machine" "node" {
  name                            = var.vm_name
  location                        = var.location
  resource_group_name             = var.resource_group_name
  size                            = var.vm_size
  admin_username                  = var.admin_username
  network_interface_ids           = [azurerm_network_interface.node.id]
  disable_password_authentication = true
  // The live setting; the provider default is false, so leaving it unstated
  // would DISABLE the VM agent's platform updates on the first apply -- the
  // same shape as GCP's deletion_protection: an imported resource inherits
  // the provider default into its plan unless the config states what is true.
  vm_agent_platform_updates_enabled = true
  // Empty means "not stated": custom_data is write-only in the Azure API, so
  // an ADOPTED machine can never have it in config without planning a replace.
  // ignore_changes below covers drift; this covers validation, which rejects
  // a non-base64 placeholder before ignore_changes is ever consulted.
  custom_data = var.custom_data_base64 == "" ? null : var.custom_data_base64

  // Same shape for the SSH key: the live node was built with the operator's
  // key, the API does not return it, and azurerm validates the config value's
  // FORMAT at plan time -- so a placeholder breaks the plan and a real-but-
  // different key plans a REPLACE of the machine that holds the data. Omit the
  // block entirely when unstated, and never let it replace the node.
  dynamic "admin_ssh_key" {
    for_each = var.admin_ssh_public_key == "" ? [] : [1]
    content {
      username   = var.admin_username
      public_key = var.admin_ssh_public_key
    }
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.node.id]
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_type
    disk_size_gb         = var.os_disk_gb
  }

  source_image_reference {
    publisher = var.image_publisher
    offer     = var.image_offer
    sku       = var.image_sku
    version   = var.image_version
  }

  lifecycle {
    // THE DISK IS THE ANALYTICS STORE. Recreating this VM to pick up a config
    // change discards everything drained into it, and Terraform will propose
    // exactly that for a change to size, image or custom_data.
    //
    // custom_data is ignored rather than pinned because it is a boot-time
    // script: changing it is meaningless to an already-booted node, but
    // Terraform reads the diff as "replace the machine".
    prevent_destroy = true
    ignore_changes  = [custom_data, admin_ssh_key]
  }

  tags = var.tags
}
