// Inputs describe existing AWS objects. Supplying them is not authorization to
// create replacements: this module must be imported before any apply.

variable "vpc_id" {
  description = "Existing VPC containing the analytics node. Looked up by the caller, never created here."
  type        = string
}

variable "vpc_cidr" {
  description = "The existing VPC CIDR allowed to reach ClickHouse on 8123/9000. Never Internet."
  type        = string
}

variable "subnet_id" {
  description = "Existing subnet containing the live node. Adoption is not permission to move it."
  type        = string
}

variable "security_group_name" {
  type = string
}

variable "security_group_description" {
  description = "The live SG description, verbatim. AWS replaces an SG to change it."
  type        = string
}

variable "ingress_ports" {
  description = "ClickHouse HTTP and native ports, each represented by its own live ingress rule."
  type        = set(number)
  default     = [8123, 9000]
}

variable "role_name" {
  description = "Existing least-privilege EC2 role used only by the ClickHouse node."
  type        = string
}

variable "role_description" {
  description = "The live role description, verbatim; omission would plan to erase it."
  type        = string
}

variable "assume_role_policy" {
  description = "JSON trust policy for the existing node role. Kept data-driven so the environment owns account-specific trust."
  type        = string
}

variable "inline_policies" {
  description = "Existing inline role policies keyed by their permanent policy names. Each entry has its own import address."
  type        = map(string)
}

variable "managed_policy_arns" {
  description = "Existing AWS-managed policy attachments. Production includes AmazonSSMManagedInstanceCore for the no-SSH operator path."
  type        = set(string)
}

variable "instance_profile_name" {
  description = "Existing instance profile attaching the dedicated role to the node."
  type        = string
}

variable "secret_name" {
  description = "Existing Secrets Manager entry name. The resource manages metadata only, never the password value."
  type        = string
}

variable "ami" {
  description = "AMI recorded on the live instance. Changes are ignored because an AMI cannot update an already-booted node."
  type        = string
}

variable "instance_type" {
  description = "Live EC2 instance type. Changing it is operational work on the analytics store, not routine drift cleanup."
  type        = string
}

variable "user_data" {
  description = "Optional creation-time bootstrap. Null for adoption; the live value is ignored and never copied into Terraform state by this root."
  type        = string
  default     = null
  nullable    = true
}

variable "instance_tags" {
  description = "Tags present on the existing EC2 instance, verbatim."
  type        = map(string)
  default     = {}
}
