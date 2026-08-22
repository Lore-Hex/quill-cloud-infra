output "clickhouse_private_ips" {
  description = "Private addresses of the three GCP ClickHouse members, keyed by permanent node name."
  value       = module.clickhouse.private_ips
}

output "clickhouse_service_account_email" {
  description = "The service account attached to every GCP ClickHouse member."
  value       = module.clickhouse.service_account_email
}
