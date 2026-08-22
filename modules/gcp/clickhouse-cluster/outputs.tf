output "private_ips" {
  description = "Private addresses of all ClickHouse members, keyed by permanent node name. No member has an external IP."
  value = {
    for name, node in google_compute_instance.node : name => node.network_interface[0].network_ip
  }
}

output "service_account_email" {
  description = "The identity attached to every ClickHouse member."
  value       = google_service_account.clickhouse.email
}
