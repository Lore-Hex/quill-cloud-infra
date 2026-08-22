// The AWS-EU production analytics layout.
//
// This root module describes what EXISTS today, so `terraform plan` is a drift
// detector rather than a wish. Every resource here was provisioned before this
// file and must be IMPORTED, not created -- see README and import.sh. A plan
// that proposes to create any of it means adoption is incomplete; applying it
// would build a second node, identity, secret or connector beside live state.
// The node's root EBS volume IS the analytics store.
//
// WHAT IS AND IS NOT HERE
//
//   IS:      the single-node operational-analytics ClickHouse layout: SG,
//            dedicated role and instance profile, inline/attached policies,
//            machine, root disk, password-secret metadata and the two existing
//            App Runner VPC connectors. The existing VPC and subnets are looked
//            up because adopting analytics is not permission to redesign its
//            surrounding network.
//
//   IS NOT:  the App Runner SERVICE `tr-eu`. quill-router
//            scripts/deploy/aws_eu_control_plane.sh deploys that service per
//            release, just as the Azure container app stays outside
//            envs/azure-prod. Image digest, environment and release sequencing
//            change together and remain owned by that deployment script.
//
//   IS NOT:  DSQL cluster tnt642i3ofzpn5z62msacutpuu. It is the billing/ledger
//            store, not analytics. The node's imported IAM policies may name it
//            because the drain reads the operational outbox there, but this
//            root does not create, alter or import the cluster itself.
//
//   IS NOT:  the VPC, public/private subnets, NAT gateways or route tables. The
//            private-egress connector references that existing fabric, whose
//            control-plane availability and cost are broader than this
//            analytics adoption and deserve their own reviewed import.
//
//   IS NOT:  ClickHouse installation, schema or drain code. Those are boot and
//            release sequences in quill-router; Terraform owns the layout.

data "aws_vpc" "clickhouse" {
  id = var.vpc_id
}

data "aws_subnet" "app_runner_private" {
  for_each = toset(var.app_runner_private_subnet_names)

  filter {
    name   = "tag:Name"
    values = [each.value]
  }

  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
}

data "aws_kms_alias" "secretsmanager" {
  name = "alias/aws/secretsmanager"
}

data "aws_iam_policy_document" "clickhouse_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }

    // EC2 instance-profile assumption does not always populate this key, so
    // hard StringEquals can fail only when cached IMDS credentials next rotate.
    condition {
      test     = "StringEqualsIfExists"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }
}

data "aws_iam_policy_document" "clickhouse" {
  statement {
    sid    = "OwnPasswordSecretOnly"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [
      "arn:aws:secretsmanager:${var.region}:${var.account_id}:secret:${var.secret_name}-*",
    ]
  }

  statement {
    sid    = "DecryptSecretsManagerKeyOnly"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = [data.aws_kms_alias.secretsmanager.target_key_arn]
  }

  // This is permission to drain ONE existing outbox, not ownership of DSQL.
  // The cluster remains explicitly outside this Terraform state.
  statement {
    sid       = "DsqlOutboxDrain"
    effect    = "Allow"
    actions   = ["dsql:DbConnect"]
    resources = ["arn:aws:dsql:${var.region}:${var.account_id}:cluster/${var.dsql_cluster_id}"]
  }

  statement {
    sid    = "EcrPullOnly"
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "QuillLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:aws:logs:${var.region}:${var.account_id}:log-group:/quill/*"]
  }
}

// This older, narrower grant may coexist with the consolidated policy above.
// It still gets a stable resource address: import.sh probes it and adopts it
// only when AWS says it is present. An API error is fatal, never "absent".
data "aws_iam_policy_document" "dsql_connect_drain" {
  statement {
    effect    = "Allow"
    actions   = ["dsql:DbConnect"]
    resources = ["arn:aws:dsql:${var.region}:${var.account_id}:cluster/${var.dsql_cluster_id}"]
  }
}

locals {
  app_runner_private_subnet_ids = [
    for name in var.app_runner_private_subnet_names : data.aws_subnet.app_runner_private[name].id
  ]
}

module "clickhouse" {
  source = "../../modules/aws/clickhouse-node"

  vpc_id    = var.vpc_id
  vpc_cidr  = data.aws_vpc.clickhouse.cidr_block
  subnet_id = var.clickhouse_subnet_id

  security_group_name        = var.security_group_name
  security_group_description = "ClickHouse for the AWS-EU cloud; VPC-internal only"

  role_name          = var.role_name
  role_description   = "Least-privilege role for ${var.instance_name}. Split from quill-enclave-role 2026-08-17."
  assume_role_policy = data.aws_iam_policy_document.clickhouse_assume_role.json
  inline_policies = {
    (var.inline_policy_name) = data.aws_iam_policy_document.clickhouse.json
    "dsql-connect-drain"    = data.aws_iam_policy_document.dsql_connect_drain.json
  }
  managed_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ]
  instance_profile_name = var.instance_profile_name

  secret_name   = var.secret_name
  ami           = var.ami
  instance_type = var.instance_type
  user_data     = null

  instance_tags = {
    Name    = var.instance_name
    Project = "tr-eu-analytics"
  }
}

// The connectors exist already and must be imported before plan/apply. They
// live at the root because joining an application runtime to a network is a
// relationship between components, not an intrinsic property of an EC2 node.
resource "aws_apprunner_vpc_connector" "clickhouse" {
  vpc_connector_name = var.clickhouse_vpc_connector_name
  subnets             = [var.clickhouse_subnet_id]
  security_groups     = [module.clickhouse.security_group_id]

  lifecycle {
    // Connector network membership is immutable. Replacement while a released
    // service references it is an outage, not ordinary Terraform convergence.
    prevent_destroy = true
  }
}

resource "aws_apprunner_vpc_connector" "private_egress" {
  vpc_connector_name = var.private_egress_vpc_connector_name
  subnets             = local.app_runner_private_subnet_ids
  security_groups     = [module.clickhouse.security_group_id]

  lifecycle {
    // All App Runner egress uses this connector; replacing it couples an
    // analytics plan to the control plane's Internet availability.
    prevent_destroy = true
  }
}
