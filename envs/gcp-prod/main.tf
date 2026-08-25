// The GCP production layout.
//
// This root module describes what EXISTS today, so `terraform plan` is a drift
// detector rather than a wish. Everything here was provisioned before this file
// and must be IMPORTED, not created -- see README. A plan that proposes to
// create any of it means the import did not happen, and applying it would build
// duplicate infrastructure beside live production. Each ClickHouse node's disk
// is one third of the analytics store; each enclave MIG serves a whole region.
//
// WHAT IS AND IS NOT HERE
//
//   IS:      the three-node operational-analytics ClickHouse cluster -- the
//            layout half: firewall rules, service account, machines and disks.
//            The existing default VPC and default us-central1 subnetwork are
//            looked up because adopting a cluster is not permission to redesign
//            its network.
//
//   IS:      the STATIC half of the enclave fleet: regional MIG shells, the
//            workload service account, and the public-TLS firewall. Stable
//            layout belongs in this same GCP production state.
//
//   IS NOT:  the MEASURED half of the enclave fleet: instance templates carry
//            the image digest and attested metadata. quill-cloud-proxy's
//            tools/deploy-gcp-mig.sh rotates them on every deploy behind
//            attestation gates plan/apply cannot express. The MIG resources
//            therefore ignore their version; Terraform owns the shells, not
//            the measured release.
//
//   IS:      the Spanner instance shell and its autoscaling policy -- adopted
//            2026-08-25 after launch day proved a hand-sized instance is the
//            whole fleet's single capacity knob (all three clouds authorize
//            and settle through it). Databases and DDL stay app-owned.
//
//   IS NOT:  the control plane, its remaining databases' schema, KMS keys,
//            secrets or load balancers. Those predate this file and are next;
//            adding them means importing live state, which is a change worth
//            reviewing on its own rather than bundled with adoption of the
//            analytics cluster.

module "clickhouse" {
  source = "../../modules/gcp/clickhouse-cluster"

  project_id      = var.project_id
  region          = var.region
  network_name    = var.network_name
  subnetwork_name = var.subnetwork_name
  nodes           = var.clickhouse_nodes

  service_account_id = var.service_account_id
  network_tag        = var.network_tag

  internal_firewall_name = var.internal_firewall_name
  internal_source_ranges = var.internal_source_ranges
  internal_ports         = var.internal_ports

  health_check_firewall_name = var.health_check_firewall_name
  health_check_source_ranges = var.health_check_source_ranges
  health_check_ports         = var.health_check_ports

  // The live objects' human-written strings, verbatim. These exist on the real
  // resources; a config that omits them plans to null them, and the plan stops
  // being a drift detector the day it is permanently dirty.
  internal_description         = "ClickHouse HTTP+native, VPC-internal only"
  health_check_description     = "GCP health checks for private ClickHouse ILB"
  service_account_display_name = "TrustedRouter ClickHouse replicas"
}

module "spanner" {
  source = "../../modules/gcp/spanner"

  project_id    = var.project_id
  instance_name = var.spanner_instance_name

  // The live object's strings, verbatim (same rule as the descriptions above).
  instance_config              = "nam6"
  display_name                 = "TrustedRouter (nam6)"
  edition                      = "ENTERPRISE_PLUS"
  default_backup_schedule_type = "AUTOMATIC"

  min_processing_units             = 1000
  max_processing_units             = 4000
  high_priority_cpu_target_percent = 55
  storage_target_percent           = 90
}

module "enclave_fleet" {
  source = "../../modules/gcp/enclave-fleet"

  project_id    = var.project_id
  network_name  = var.network_name
  regional_migs = var.enclave_regional_migs

  service_account_id           = var.enclave_service_account_id
  service_account_display_name = "Quill Cloud workload (Confidential Space)"

  public_tls_firewall_name = var.enclave_public_tls_firewall_name
  network_tag              = var.enclave_network_tag
}
