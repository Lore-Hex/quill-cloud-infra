output "clickhouse_private_ips" {
  description = "Private addresses of the three GCP ClickHouse members, keyed by permanent node name."
  value       = module.clickhouse.private_ips
}

output "clickhouse_service_account_email" {
  description = "The service account attached to every GCP ClickHouse member."
  value       = module.clickhouse.service_account_email
}

output "enclave_regional_mig_ids" {
  description = "Static regional enclave MIG shells keyed by short region name."
  value       = module.enclave_fleet.regional_mig_ids
}

output "enclave_service_account_email" {
  description = "Workload identity shared by the measured enclave templates."
  value       = module.enclave_fleet.service_account_email
}
