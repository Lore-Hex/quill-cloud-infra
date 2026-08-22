output "regional_mig_ids" {
  description = "Regional MIG resource ids keyed by the short region name."
  value = {
    for region, mig in google_compute_region_instance_group_manager.regional : region => mig.id
  }
}

output "regional_instance_groups" {
  description = "Underlying regional instance-group URLs, for attaching the static fleet shells to backends."
  value = {
    for region, mig in google_compute_region_instance_group_manager.regional : region => mig.instance_group
  }
}

output "service_account_email" {
  description = "Workload identity used by the enclave fleet."
  value       = google_service_account.workload.email
}
