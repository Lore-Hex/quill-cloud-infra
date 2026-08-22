output "clickhouse_url" {
  description = "Set TR_OPERATIONAL_ANALYTICS_CLICKHOUSE_URL to this on the Azure control plane."
  value       = module.clickhouse.clickhouse_url
}

output "clickhouse_identity_principal_id" {
  value = module.clickhouse.identity_principal_id
}
