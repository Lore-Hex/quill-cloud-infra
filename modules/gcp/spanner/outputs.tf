output "instance_id" {
  value = google_spanner_instance.this.id
}

output "autoscaling_limits" {
  value = {
    min = var.min_processing_units
    max = var.max_processing_units
  }
}
