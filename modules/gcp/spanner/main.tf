// The Spanner instance that carries every billed request on every cloud.
//
// All three clouds' gateways authorize and settle through this one instance
// (AWS and Azure call the GCP control plane for billing), which makes its
// capacity the whole fleet's capacity. On 2026-08-25 -- launch day -- it was
// still statically sized at 300 processing units from quieter times; the
// announcement's first traffic wave quadrupled request volume, authorize
// latency went from sub-second to 30 seconds, and all three public status
// pages flipped to "Major outage" within ten minutes of each other while the
// operator hand-ran a resize. Nothing was down; everything was queued.
//
// Hence AUTOSCALING, owned here rather than hand-set: min is the floor that
// launch-day baseline proved comfortable (p50 0.89s at 1000 PU), max caps the
// bill against runaways, and the CPU target is deliberately below the 65%
// default because nam6 is a multi-region config whose write quorum deserves
// headroom during zone events. The autoscaler reacts to SUSTAINED load over
// minutes; the seconds-scale gap in front of it is covered by the gateway's
// Retry-After backoff headers, and that pairing is load-tested by the launch
// itself: the herd dispersed before the manual resize even landed.
//
// WHAT IS NOT HERE: the databases and their DDL. Schema belongs to the
// application's migration tooling (quill-router), exactly as the enclave
// fleet's measured instance templates belong to the attested deploy pipeline.
// Terraform owns the instance shell and its capacity policy, not the schema
// release sequence.

terraform {
  required_version = ">= 1.7"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

resource "google_spanner_instance" "this" {
  project      = var.project_id
  name         = var.instance_name
  config       = var.instance_config
  display_name = var.display_name

  // The live instance's edition and backup posture, verbatim. Omitting either
  // plans a downgrade the day the import lands (defaults strip live
  // protections -- ENTERPRISE_PLUS would fall back to the API default).
  edition                      = var.edition
  default_backup_schedule_type = var.default_backup_schedule_type

  // Autoscaling replaces the static processing_units entirely; the two are
  // mutually exclusive on this resource. The first plan after import shows
  // exactly that swap -- static 1000 PU out, this policy in -- as an
  // in-place update. Anything proposing replacement means an immutable
  // attribute (name/config/edition) diverged from live: STOP and reconcile.
  autoscaling_config {
    autoscaling_limits {
      min_processing_units = var.min_processing_units
      max_processing_units = var.max_processing_units
    }
    autoscaling_targets {
      high_priority_cpu_utilization_percent = var.high_priority_cpu_target_percent
      storage_utilization_percent           = var.storage_target_percent
    }
  }

  // This instance IS the billing ledger's home. force_destroy would let a
  // destroy plan delete it with databases still inside; prevent_destroy makes
  // even proposing that an error.
  force_destroy = false

  lifecycle {
    prevent_destroy = true
  }
}
