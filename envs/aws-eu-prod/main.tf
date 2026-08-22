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

module "clickhouse" {
  // The 8123 SG reference is tr-cp-fargate-sg ("TR control-plane Fargate
  // tasks"): the plane's own read path into its analytics store.
  ingress_rules = {
    http   = { port = 8123, security_groups = [var.control_plane_fargate_sg_id] }
    native = { port = 9000 }
  }

  source = "../../modules/aws/clickhouse-node"

  vpc_id    = var.vpc_id
  vpc_cidr  = data.aws_vpc.clickhouse.cidr_block
  subnet_id = var.clickhouse_subnet_id

  security_group_name        = var.security_group_name
  security_group_description = "ClickHouse for the AWS-EU cloud; VPC-internal only"

  role_name = var.role_name
  // The live string VERBATIM, including the second sentence. It is incident
  // documentation living in AWS -- the record of why this role was split and
  // what the old shared role over-granted. Truncating it in config would have
  // applied the truncation to the cloud.
  role_description   = "Least-privilege role for ${var.instance_name}. Split from quill-enclave-role 2026-08-17: that role granted secretsmanager quill/* (~40 provider API keys) and kms:Decrypt on key/* to a non-enclave analytics host."
  assume_role_policy = data.aws_iam_policy_document.clickhouse_assume_role.json
  inline_policies = {
    (var.inline_policy_name) = data.aws_iam_policy_document.clickhouse.json
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
  subnets            = [var.clickhouse_subnet_id]
  security_groups    = [module.clickhouse.security_group_id]

  lifecycle {
    // Connector network membership is immutable. Replacement while a released
    // service references it is an outage, not ordinary Terraform convergence.
    prevent_destroy = true
  }
}

resource "aws_apprunner_vpc_connector" "private_egress" {
  vpc_connector_name = var.private_egress_vpc_connector_name
  // The LIVE connector's own subnets and its own security group, verbatim.
  // A connector is immutable -- App Runner replaces it on any change -- so a
  // guessed value here is not drift, it is a plan to DESTROY the connector
  // every App Runner egress path rides on. It does not share the ClickHouse
  // node's SG, and assuming it did is exactly the kind of tidy-looking
  // unification an import plan exists to catch.
  subnets         = var.private_egress_subnet_ids
  security_groups = var.private_egress_security_group_ids

  lifecycle {
    // All App Runner egress uses this connector; replacing it couples an
    // analytics plan to the control plane's Internet availability.
    prevent_destroy = true
  }
}
