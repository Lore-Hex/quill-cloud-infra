variable "project_id" {
  description = "GCP project holding the production deployment."
  type        = string
  default     = "quill-cloud-proxy"
}

variable "region" {
  description = "The cluster spans three zones in this region so a zonal failure does not remove Keeper quorum."
  type        = string
  default     = "us-central1"
}

variable "network_name" {
  description = "Existing VPC shared by the live nodes. It is looked up, never created by this environment."
  type        = string
  default     = "default"
}

variable "subnetwork_name" {
  description = "Existing regional subnetwork shared by the live nodes. It is looked up, never created by this environment."
  type        = string
  default     = "default"
}

variable "clickhouse_nodes" {
  description = "The three live ClickHouse members keyed by permanent name. Keep this a map: removing a middle member must not renumber the remaining machines."
  // This type is a COPY of the module's, and copies drift: the first version
  // omitted `metadata` here after adding it there, and Terraform's type
  // conversion silently STRIPPED the attribute from the default on its way
  // into the module -- the plan kept proposing to null live metadata while
  // this file visibly declared it. An attribute the type does not name does
  // not exist, no matter what the value says.
  type = map(object({
    zone         = string
    machine_type = string
    disk_size_gb = number
    metadata     = optional(map(string), {})
  }))
  default = {
    tr-clickhouse-1 = {
      zone         = "us-central1-a"
      machine_type = "e2-standard-4"
      disk_size_gb = 500
    }
    // Nodes 2 and 3 carry a pointer to the ClickHouse password's Secret
    // Manager NAME; node 1 does not. That asymmetry is the live state, not a
    // typo in this file -- describing it keeps the plan clean, and anyone
    // reconciling it should do so on the machines first, then here.
    tr-clickhouse-2 = {
      zone         = "us-central1-b"
      machine_type = "e2-standard-4"
      disk_size_gb = 500
      metadata     = { clickhouse-password-secret = "trustedrouter-clickhouse-password" }
    }
    tr-clickhouse-3 = {
      zone         = "us-central1-c"
      machine_type = "e2-standard-4"
      disk_size_gb = 500
      metadata     = { clickhouse-password-secret = "trustedrouter-clickhouse-password" }
    }
  }
}

variable "service_account_id" {
  description = "Account id for tr-clickhouse@quill-cloud-proxy.iam.gserviceaccount.com, attached to every node with the cloud-platform scope."
  type        = string
  default     = "tr-clickhouse"
}

variable "network_tag" {
  description = "Target tag shared by both firewall rules and every cluster member."
  type        = string
  default     = "tr-clickhouse"
}

variable "internal_firewall_name" {
  type    = string
  default = "tr-clickhouse-internal"
}

variable "internal_source_ranges" {
  description = "The default VPC's private address space. Never Internet."
  type        = list(string)
  default     = ["10.128.0.0/9"]
}

variable "internal_ports" {
  description = "ClickHouse HTTP/native plus Keeper client/raft. Omitting 9181/9234 would describe three nodes but not the replicated cluster that exists."
  type        = list(string)
  default     = ["8123", "9000", "9181", "9234"]
}

variable "health_check_firewall_name" {
  type    = string
  default = "tr-clickhouse-health-check"
}

variable "health_check_source_ranges" {
  description = "Google's documented health-check source ranges, permitted to reach only port 8123."
  type        = list(string)
  default     = ["35.191.0.0/16", "130.211.0.0/22"]
}

variable "health_check_ports" {
  type    = list(string)
  default = ["8123"]
}
