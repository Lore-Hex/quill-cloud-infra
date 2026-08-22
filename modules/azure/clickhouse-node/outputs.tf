output "private_ip" {
  description = "The address the control plane points TR_OPERATIONAL_ANALYTICS_CLICKHOUSE_URL at. Private by construction."
  value       = azurerm_network_interface.node.private_ip_address
}

output "clickhouse_url" {
  description = "Ready to paste into the control plane's env."
  value       = "http://${azurerm_network_interface.node.private_ip_address}:8123"
}

output "identity_principal_id" {
  description = <<-EOT
    Grant this "Key Vault Secrets User" on the vault holding the ClickHouse
    password. Deliberately an OUTPUT rather than a role assignment inside the
    module: granting access to a vault that holds provider secrets should be an
    explicit line somebody reviews, not a side effect of adding a node.
  EOT
  value       = azurerm_user_assigned_identity.node.principal_id
}

output "identity_client_id" {
  description = "The client_id cloud-init uses when asking IMDS for a vault token."
  value       = azurerm_user_assigned_identity.node.client_id
}

output "subnet_id" {
  value = azurerm_subnet.clickhouse.id
}
