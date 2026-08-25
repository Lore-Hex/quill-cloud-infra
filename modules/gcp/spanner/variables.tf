variable "project_id" {
  type = string
}

variable "instance_name" {
  type = string
}

variable "instance_config" {
  type        = string
  description = "Instance config id, e.g. nam6. Immutable: a mismatch with live forces replacement."
}

variable "display_name" {
  type = string
}

variable "edition" {
  type        = string
  description = "Live edition, verbatim (ENTERPRISE_PLUS). Omission plans a downgrade."
}

variable "default_backup_schedule_type" {
  type = string
}

variable "min_processing_units" {
  type        = number
  description = "Autoscaler floor. 1000 = the launch-day-proven baseline; below it the 2026-08-25 knee returns on quiet-night sizing."
}

variable "max_processing_units" {
  type        = number
  description = "Autoscaler ceiling: caps spend against runaways."
}

variable "high_priority_cpu_target_percent" {
  type        = number
  description = "Scale-up target. Below the 65% default on purpose: nam6 multi-region write quorum deserves headroom."
}

variable "storage_target_percent" {
  type = number
}
