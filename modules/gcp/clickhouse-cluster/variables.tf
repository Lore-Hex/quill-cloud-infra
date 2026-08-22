variable "project_id" {
  description = "GCP project holding the production analytics cluster."
  type        = string
}

variable "region" {
  description = "GCP region containing the existing default subnetwork. All nodes remain in this region while spreading across zones for quorum."
  type        = string
}

variable "network_name" {
  description = "Existing VPC to look up, not create. Production uses default because moving the live private cluster to an invented VPC would be a migration, not adoption."
  type        = string
}

variable "subnetwork_name" {
  description = "Existing regional subnetwork to look up, not create."
  type        = string
}

variable "nodes" {
  description = "ClickHouse members keyed by permanent node name. A map makes removal stable: deleting one member never renumbers the others. Each disk is one third of the analytics store."
  type = map(object({
    zone         = string
    machine_type = string
    disk_size_gb = number
  }))
}

variable "service_account_id" {
  description = "Account id, without the project domain, for the identity attached to every ClickHouse node."
  type        = string
}

variable "network_tag" {
  description = "Tag shared by every node and targeted by both narrowly-scoped ingress rules."
  type        = string
}

variable "internal_firewall_name" {
  type = string
}

variable "internal_source_ranges" {
  description = "Private source ranges allowed to reach ClickHouse and Keeper. Never Internet."
  type        = list(string)
}

variable "internal_ports" {
  description = "ClickHouse HTTP/native and Keeper client/raft ports reachable inside the VPC. Keeper is what makes this a replicated cluster."
  type        = list(string)
}

variable "health_check_firewall_name" {
  type = string
}

variable "health_check_source_ranges" {
  description = "Google's health-check ranges. They receive HTTP health access only, never ClickHouse native or Keeper access."
  type        = list(string)
}

variable "health_check_ports" {
  description = "Ports visible to Google's health checkers. Production exposes only ClickHouse HTTP on 8123."
  type        = list(string)
}
