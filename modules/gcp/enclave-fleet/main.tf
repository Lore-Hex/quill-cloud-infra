// The GCP enclave fleet is deliberately split between two owners.
//
// MEASURED: instance templates carry the workload image digest and attested
// metadata. quill-cloud-proxy/tools/deploy-gcp-mig.sh rotates those templates
// on every deploy, with attestation gates Terraform plan/apply cannot express.
// Terraform must never try to reconcile that release sequence.
//
// STATIC: the regional MIG shells, workload service account, and public-TLS
// firewall are stable layout. Terraform owns those objects. Each MIG therefore
// declares the template needed for initial adoption but ignores version drift
// after the measured deploy tooling rotates it.

terraform {
  required_version = ">= 1.7"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

data "google_compute_network" "enclave" {
  name    = var.network_name
  project = var.project_id
}

resource "google_service_account" "workload" {
  account_id   = var.service_account_id
  project      = var.project_id
  display_name = var.service_account_display_name

  lifecycle {
    // Recreating a service account preserves its email address but changes its
    // immutable identity. Existing IAM bindings still point at the deleted
    // identity, leaving apparently healthy enclave VMs unable to reach their
    // workload dependencies. This is the same hazard as the ClickHouse SA.
    prevent_destroy = true
  }
}

resource "google_compute_firewall" "public_tls" {
  name    = var.public_tls_firewall_name
  project = var.project_id
  network = data.google_compute_network.enclave.self_link

  direction     = "INGRESS"
  source_ranges = ["0.0.0.0/0"]
  target_tags   = [var.network_tag]

  // 0.0.0.0/0 IS INTENTIONAL. These machines are the public, attested TLS
  // gateways: TLS terminates inside the measured workload, and every Internet
  // client must be able to reach that workload on 443. Do not "tighten" this
  // range without replacing the public ingress design.
  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  // Unlike a regional MIG shell or an IAM identity, this stateless rule can be
  // recreated without changing resource identity, so it has no prevent_destroy.
}

resource "google_compute_region_instance_group_manager" "regional" {
  for_each = var.regional_migs

  name               = each.value.name
  project            = var.project_id
  region             = each.value.region
  base_instance_name = each.value.name
  target_size        = each.value.target_size

  distribution_policy_zones = each.value.zones

  // This is the template present at the import moment, not a release pin for
  // Terraform to enforce. The measured deployment rotates it after attestation.
  version {
    instance_template = each.value.instance_template
  }

  update_policy {
    type                         = "PROACTIVE"
    instance_redistribution_type = "PROACTIVE"
    minimal_action               = "REPLACE"
    replacement_method           = "SUBSTITUTE"
    max_surge_fixed              = 3
    max_unavailable_fixed        = 0
  }

  // No auto_healing_policies block: the live fleet has no autohealing policy.

  lifecycle {
    // Deleting a MIG is a regional outage, even if its instances can later be
    // reconstructed from a measured template.
    prevent_destroy = true

    // MEASURED ownership boundary: deploy-gcp-mig.sh changes the MIG version
    // only after checks plan/apply cannot represent. Refresh may observe that
    // rotation, but Terraform must not roll the fleet back to this file's
    // import-moment template.
    ignore_changes = [version]
  }
}
