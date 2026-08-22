// One cloud's operational-analytics store: a private, three-node ClickHouse
// cluster with Keeper replication.
//
// settle -> tr_operational_analytics_outbox (Postgres) -> drain -> HERE
//
// Each cloud owns its own analytics, with no cross-cloud replication. That is
// the same rule the rest of the separation architecture follows, and for a
// regional deployment it is also what lets a data-residency claim survive
// contact with an auditor: operational rows about that region's traffic never
// leave it.
//
// GCP is deliberately different from the single-node Azure and AWS layouts.
// Every node holds one third of the replicated analytics store, and Keeper on
// 9181/9234 is the coordination layer that makes these three machines a
// cluster rather than three unrelated ClickHouse servers.
//
// ---------------------------------------------------------------------------
// WHAT THIS MODULE DOES NOT DO, DELIBERATELY
// ---------------------------------------------------------------------------
//   * It does not install ClickHouse or Keeper. That happens in the startup
//     script because the package install, the schema, the cluster topology and
//     the password fetch are a boot-time sequence with retries -- not
//     declarative state Terraform can converge on. Terraform owns the LAYOUT:
//     the firewall, the identity, the disks and the machines.
//
//   * It does not invent a network for resources that already live on GCP's
//     default VPC and default us-central1 subnetwork. Those objects are looked
//     up, not created, so adopting this cluster cannot reroute the enclave
//     fleet or anything else already sharing that network.
//
//   * It does not manage the drain. The drain is code shipped onto the nodes
//     and a systemd unit, not infrastructure layout.
//
// ---------------------------------------------------------------------------
// WHY THE NODES ARE PRIVATE
// ---------------------------------------------------------------------------
// A ClickHouse with a public address is protected by a password alone. The
// control plane that reads it is already inside this VPC, so no network
// interface has an access_config and therefore none has an external IP. The
// only non-VPC ingress is 8123 from Google's documented health-check ranges.

terraform {
  required_version = ">= 1.7"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

data "google_compute_network" "clickhouse" {
  name    = var.network_name
  project = var.project_id
}

data "google_compute_subnetwork" "clickhouse" {
  name    = var.subnetwork_name
  project = var.project_id
  region  = var.region
}

resource "google_compute_firewall" "internal" {
  name    = var.internal_firewall_name
  project = var.project_id
  network = data.google_compute_network.clickhouse.self_link

  direction     = "INGRESS"
  source_ranges = var.internal_source_ranges
  target_tags   = [var.network_tag]

  // 8123 (HTTP), 9000 (native), and Keeper's 9181/9234, from inside the
  // default VPC only. Never Internet/0.0.0.0/0: see the header.
  allow {
    protocol = "tcp"
    ports    = var.internal_ports
  }
}

resource "google_compute_firewall" "health_check" {
  name    = var.health_check_firewall_name
  project = var.project_id
  network = data.google_compute_network.clickhouse.self_link

  direction     = "INGRESS"
  source_ranges = var.health_check_source_ranges
  target_tags   = [var.network_tag]

  // Health checks need the HTTP endpoint and nothing else. In particular,
  // Google's probes never need the native protocol or either Keeper port.
  allow {
    protocol = "tcp"
    ports    = var.health_check_ports
  }
}

resource "google_service_account" "clickhouse" {
  account_id = var.service_account_id
  project    = var.project_id

  lifecycle {
    // A recreated service account may have the same email but it gets a new
    // immutable identity. IAM bindings keyed to the old identity no longer
    // authorize the nodes, so a tidy-looking replacement can leave all three
    // machines booted but unable to reach what their workload needs.
    prevent_destroy = true
  }
}

resource "google_compute_instance" "node" {
  // Names, not numeric positions, are the stable identity of cluster members.
  // Removing tr-clickhouse-2 must never rename or recreate tr-clickhouse-3.
  for_each = var.nodes

  name         = each.key
  project      = var.project_id
  zone         = each.value.zone
  machine_type = each.value.machine_type
  tags         = [var.network_tag]

  boot_disk {
    initialize_params {
      size = each.value.disk_size_gb
    }
  }

  network_interface {
    network    = data.google_compute_network.clickhouse.self_link
    subnetwork = data.google_compute_subnetwork.clickhouse.self_link
    // No access_config. Its absence is the security property.
  }

  service_account {
    email  = google_service_account.clickhouse.email
    scopes = ["cloud-platform"]
  }

  lifecycle {
    // EACH DISK IS A THIRD OF THE ANALYTICS STORE. Recreating one of these
    // machines to pick up a config change discards a cluster member's data,
    // and doing that casually can turn a degraded cluster into lost quorum.
    prevent_destroy = true

    // startup-script is boot provisioning: changing it is meaningless to an
    // already-booted node, but Terraform can read the metadata diff as a
    // machine replacement. attached_disk is ignored because operators perform
    // manual disk recovery and expansion; Terraform must not turn that work
    // into a detach or replacement of part of the analytics store.
    ignore_changes = [metadata["startup-script"], attached_disk]
  }
}
