// The GCP production analytics layout.
//
// This root module describes what EXISTS today, so `terraform plan` is a drift
// detector rather than a wish. Everything here was provisioned before this file
// and must be IMPORTED, not created -- see README. A plan that proposes to
// create any of it means the import did not happen, and applying it would build
// a second copy of a live analytics cluster beside the one holding the data.
// Each node's disk is one third of that store.
//
// WHAT IS AND IS NOT HERE
//
//   IS:      the three-node operational-analytics ClickHouse cluster -- the
//            layout half: firewall rules, service account, machines and disks.
//            The existing default VPC and default us-central1 subnetwork are
//            looked up because adopting a cluster is not permission to redesign
//            its network.
//
//   IS NOT:  the enclave managed instance groups (`quill-enclave-mig-*`). Those
//            are measured deploys owned by quill-cloud-proxy tooling: the
//            workload image, launch policy and live attestation must move as a
//            coordinated release. plan/apply cannot express that verification
//            step, so the enclave fleet stays in gcp/bringup.sh and the proxy's
//            deployment tools.
//
//   IS NOT:  the control plane, its databases, KMS keys, secrets or load
//            balancers. Those predate this file and are next; adding them means
//            importing live state, which is a change worth reviewing on its own
//            rather than bundled with adoption of the analytics cluster.

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
