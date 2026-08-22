// Outputs identify imported resources only. The ClickHouse password value is
// deliberately neither managed nor exposed by this environment.

output "clickhouse_instance_id" {
  value = module.clickhouse.instance_id
}

output "clickhouse_root_volume_id" {
  description = "The analytics-store EBS volume (live: vol-01bee1fe737792750)."
  value       = module.clickhouse.root_volume_id
}

output "clickhouse_url" {
  description = "Set TR_OPERATIONAL_ANALYTICS_CLICKHOUSE_URL to this on the AWS-EU control plane."
  value       = module.clickhouse.clickhouse_url
}

output "clickhouse_role_arn" {
  value = module.clickhouse.role_arn
}

output "clickhouse_secret_arn" {
  description = "Secret metadata ARN only, never its value."
  value       = module.clickhouse.secret_arn
}

output "app_runner_vpc_connector_arns" {
  description = "Existing connectors consumed by quill-router's per-release App Runner deployment."
  value = {
    clickhouse     = aws_apprunner_vpc_connector.clickhouse.arn
    private_egress = aws_apprunner_vpc_connector.private_egress.arn
  }
}
