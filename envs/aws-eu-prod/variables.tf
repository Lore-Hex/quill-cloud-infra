// Defaults are identifiers of the live AWS-EU layout. They support import;
// they are not permission to create a parallel copy when state is empty.

variable "account_id" {
  description = "AWS account holding the production EU deployment. The provider refuses any other account."
  type        = string
  default     = "330422590279"
}

variable "region" {
  description = "Paris, colocated with the EU control plane and its region-owned analytics."
  type        = string
  default     = "eu-west-3"
}

variable "vpc_id" {
  description = "Existing VPC shared by the node and App Runner connectors. Looked up, never created here."
  type        = string
  default     = "vpc-05b829b9cae6a9cd8"
}

variable "clickhouse_subnet_id" {
  description = "Existing eu-west-3a subnet containing the live ClickHouse node and original connector."
  type        = string
  default     = "subnet-06e58bd9bca166a94"
}

variable "app_runner_private_subnet_names" {
  description = "Existing per-AZ private subnets behind NAT. Looked up by permanent Name tags, never created by this environment."
  type        = list(string)
  default = [
    "tr-eu-private-eu-west-3a",
    "tr-eu-private-eu-west-3b",
  ]
}

variable "ami" {
  description = "AMI on the imported node. The module ignores later AMI drift because changing it cannot update a running machine."
  type        = string
  default     = "ami-0e8d619f32b216044"
}

variable "instance_type" {
  description = "Live node size; ClickHouse values memory more than cores."
  type        = string
  default     = "m5.large"
}

variable "instance_name" {
  type    = string
  default = "tr-eu-clickhouse-1"
}

variable "security_group_name" {
  type    = string
  default = "tr-eu-clickhouse-sg"
}

variable "role_name" {
  type    = string
  default = "tr-eu-clickhouse-role"
}

variable "instance_profile_name" {
  type    = string
  default = "tr-eu-clickhouse-instance-profile"
}

variable "inline_policy_name" {
  type    = string
  default = "tr-eu-clickhouse-policy"
}

variable "secret_name" {
  description = "Existing password secret. Terraform adopts metadata only and never reads or writes its value."
  type        = string
  default     = "quill/tr-eu-clickhouse-password"
}

variable "clickhouse_vpc_connector_name" {
  type    = string
  default = "tr-eu-vpc"
}

variable "private_egress_vpc_connector_name" {
  type    = string
  default = "tr-eu-vpc-private"
}

variable "dsql_cluster_id" {
  description = "Existing billing/ledger DSQL cluster named only to scope the drain's IAM permission. The cluster itself is out of scope."
  type        = string
  default     = "tnt642i3ofzpn5z62msacutpuu"
}

variable "private_egress_subnet_ids" {
  description = "The live tr-eu-vpc-private connector's subnets, verbatim. Immutable on the connector: a wrong value plans its replacement."
  type        = list(string)
  default     = ["subnet-02bf657680a20cc32", "subnet-02c00be7f803c5ec9"]
}

variable "private_egress_security_group_ids" {
  description = "The live connector's OWN security group -- not the ClickHouse node's."
  type        = list(string)
  default     = ["sg-024287194699657d8"]
}

variable "control_plane_fargate_sg_id" {
  description = "tr-cp-fargate-sg -- the control plane's Fargate SG, admitted to 8123 on the live rule."
  type        = string
  default     = "sg-0158d8dbd22c5038f"
}
