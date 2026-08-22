// Outputs expose identifiers from the imported layout only. No secret value is
// represented by this module or returned here.

output "instance_id" {
  description = "The imported AWS-EU ClickHouse instance."
  value       = aws_instance.node.id
}

output "private_ip" {
  description = "The VPC address the control plane uses for ClickHouse."
  value       = aws_instance.node.private_ip
}

output "clickhouse_url" {
  description = "Ready to pass to TR_OPERATIONAL_ANALYTICS_CLICKHOUSE_URL."
  value       = "http://${aws_instance.node.private_ip}:8123"
}

output "root_volume_id" {
  description = "The imported root EBS volume. This disk is the analytics store."
  value       = aws_instance.node.root_block_device[0].volume_id
}

output "security_group_id" {
  value = aws_security_group.clickhouse.id
}

output "role_arn" {
  description = "Dedicated least-privilege identity attached to the node."
  value       = aws_iam_role.node.arn
}

output "instance_profile_name" {
  value = aws_iam_instance_profile.node.name
}

output "secret_arn" {
  description = "Secret metadata ARN only; the password value is not a Terraform resource."
  value       = aws_secretsmanager_secret.clickhouse_password.arn
}
