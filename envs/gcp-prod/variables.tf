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

variable "enclave_regional_migs" {
  description = "The four live regional enclave MIG shells. Template names record only the import moment; measured deploy tooling owns every subsequent rotation."
  type = map(object({
    name              = string
    region            = string
    zones             = list(string)
    target_size       = number
    instance_template = string
    // Declared in BOTH copies of this type or terraform's conversion silently
    // strips it from the default on the way into the module -- the third time
    // this repo has hit that trap; see the clickhouse_nodes comment.
    redistribution = optional(string, "PROACTIVE")
  }))
  default = {
    us = {
      name              = "quill-enclave-mig-us"
      region            = "us-central1"
      zones             = ["us-central1-b", "us-central1-c", "us-central1-f"]
      target_size       = 2
      instance_template = "quill-enclave-tpl-us-313" // c3-standard-4 at import
    }
    useast4 = {
      name              = "quill-enclave-mig-useast4"
      region            = "us-east4"
      zones             = ["us-east4-a", "us-east4-b", "us-east4-c"]
      target_size       = 2
      instance_template = "quill-enclave-tpl-useast4-176" // c3-standard-4 at import
      // Live asymmetry: this MIG alone runs NONE while its siblings run
      // PROACTIVE. Reconcile on the MIG first, here second -- never by
      // letting this file "fix" it as a side effect of an unrelated apply.
      redistribution = "NONE"
    }
    sa = {
      name              = "quill-enclave-mig-sa"
      region            = "southamerica-east1"
      zones             = ["southamerica-east1-a", "southamerica-east1-b", "southamerica-east1-c"]
      target_size       = 2
      instance_template = "quill-enclave-tpl-sa-024" // n2d-standard-4 at import
    }
    eu = {
      name              = "quill-enclave-mig-eu"
      region            = "europe-west4"
      zones             = ["europe-west4-a", "europe-west4-b", "europe-west4-c"]
      target_size       = 2
      instance_template = "quill-enclave-tpl-eu-295" // c3-standard-4 at import
    }
  }
}

variable "enclave_service_account_id" {
  description = "Account id for quill-workload@quill-cloud-proxy.iam.gserviceaccount.com, shared by the measured enclave templates."
  type        = string
  default     = "quill-workload"
}

variable "enclave_public_tls_firewall_name" {
  description = "Public ingress rule for the attested TLS gateways."
  type        = string
  default     = "quill-allow-public-tls"
}

variable "enclave_network_tag" {
  description = "Target tag applied by enclave templates and selected by the public-TLS firewall."
  type        = string
  default     = "quill-enclave"
}
