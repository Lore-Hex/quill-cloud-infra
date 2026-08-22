// One cloud's operational-analytics store: a single VPC-restricted
// ClickHouse node.
//
// settle -> tr_operational_analytics_outbox (DSQL/Postgres) -> drain -> HERE
//
// Each cloud owns its own analytics, with no cross-cloud replication. That is
// the same rule the rest of the separation architecture follows, and for a
// regional deployment it is also what lets a data-residency claim survive
// contact with an auditor: operational rows about that region's traffic never
// leave it.
//
// Every resource below ALREADY EXISTS. This module is an adoption boundary,
// not a creation recipe: import first, then use plan as a drift detector.
//
// ---------------------------------------------------------------------------
// WHAT THIS MODULE DOES NOT DO, DELIBERATELY
// ---------------------------------------------------------------------------
//   * It does not install ClickHouse. That happened in user_data before this
//     module existed, because the package install, schema and password fetch
//     are a boot-time sequence with retries -- not declarative state Terraform
//     can converge on. Terraform owns the LAYOUT: SG, identity, disk, machine.
//
//   * It does not invent a network for resources that already live in an
//     existing VPC and subnet. Their ids are inputs, so importing this node
//     cannot reroute the control plane or anything else sharing that network.
//
//   * It does not manage the drain. The drain is code shipped onto the node
//     and a systemd unit -- see quill-router
//     scripts/deploy/aws_eu_clickhouse_drain_install.sh.
//
// ---------------------------------------------------------------------------
// WHY CLICKHOUSE INGRESS IS PRIVATE
// ---------------------------------------------------------------------------
// A ClickHouse reachable from the Internet is protected by a password alone.
// The control plane reaches this node through an App Runner VPC connector, so
// its SG admits 8123/9000 from the VPC CIDR only. There is no SSH ingress and
// no key pair; SSM through the instance role is the break-glass path.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

resource "aws_security_group" "clickhouse" {
  name        = var.security_group_name
  description = var.security_group_description
  vpc_id      = var.vpc_id

  // One rule PER PORT because that is the shape the live SG has. Combining
  // 8123 and 9000 into a range would also expose every port between them.
  // 8123 also admits the control plane's Fargate tasks BY SECURITY GROUP.
  // That reference is live access: omitting it does not tidy the config, it
  // plans to sever the control plane from its own analytics store. Modeled
  // per-port so 9000 stays VPC-only.
  dynamic "ingress" {
    for_each = var.ingress_rules
    content {
      from_port       = ingress.value.port
      to_port         = ingress.value.port
      protocol        = "tcp"
      cidr_blocks     = [var.vpc_cidr]
      security_groups = ingress.value.security_groups
    }
  }

  // This is the default egress rule the existing SG was created with. It is
  // stated because importing the group and omitting inline egress would make
  // the first plan propose deleting live egress.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_role" "node" {
  name               = var.role_name
  description        = var.role_description
  assume_role_policy = var.assume_role_policy

  lifecycle {
    // Recreating the role produces a new principal id. A familiar name is not
    // the same identity to every policy that already trusts this node.
    prevent_destroy = true
  }
}

// Inline and managed grants are separate, data-driven resources. Putting
// inline_policy blocks on aws_iam_role makes unrelated role edits authoritative
// over every inline policy and turns an optional live grant into silent
// deletion. Stable map keys also give import.sh an address for each grant.
resource "aws_iam_role_policy" "inline" {
  for_each = var.inline_policies

  name   = each.key
  role   = aws_iam_role.node.name
  policy = each.value
}

resource "aws_iam_role_policy_attachment" "managed" {
  for_each = var.managed_policy_arns

  role       = aws_iam_role.node.name
  policy_arn = each.value
}

resource "aws_iam_instance_profile" "node" {
  name = var.instance_profile_name
  role = aws_iam_role.node.name
}

resource "aws_secretsmanager_secret" "clickhouse_password" {
  // Metadata only. The password value is an aws_secretsmanager_secret_version,
  // deliberately absent here so neither configuration nor state learns it.
  name = var.secret_name

  lifecycle {
    // Losing the metadata object also loses the stable name the node and
    // control plane resolve. Password rotation is a secret-version operation,
    // not a reason to replace this resource.
    prevent_destroy = true
  }
}

resource "aws_instance" "node" {
  ami                    = var.ami
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.clickhouse.id]
  iam_instance_profile   = aws_iam_instance_profile.node.name
  user_data              = var.user_data

  // No key_name. The live node has no key pair and SSM is the operator path.

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  // !!! REVIEWER FOLLOW-UP -- MAKE THIS A SEPARATE, EXPLICIT COMMIT !!!
  // ON, deliberately, since 2026-08-22 -- this was the one analytics node in
  // the fleet with no termination guard. Its GCP siblings carry
  // deletion_protection and disks that outlive their machines; this node had
  // neither, and its root volume IS the store. Flipped as an explicit,
  // reviewed apply immediately after adoption, not smuggled into the import.
  disable_api_termination = true

  root_block_device {
    // The live root volume is DeleteOnTermination=TRUE. The disk IS the
    // analytics store. Do not silently rewrite history during adoption: first
    // import and prove the plan, then make false here and true above an
    // explicit protection change somebody can review on its own.
    // The disk must OUTLIVE the machine: with this true, any instance
    // deletion -- console mistake, quota reaper, migration -- took the
    // analytics store with it. Same rationale as auto_delete=false on GCP.
    delete_on_termination = false
  }

  lifecycle {
    // THE ROOT VOLUME IS THE ANALYTICS STORE. Recreating this instance to pick
    // up configuration drift discards the store under today's live
    // DeleteOnTermination setting.
    prevent_destroy = true

    // AMI and user_data are boot-time inputs. Changing either on an already
    // running node cannot converge ClickHouse, but Terraform can interpret the
    // difference as machine churn. Workload upgrades stay in deployment tools.
    ignore_changes = [ami, user_data]
  }

  tags = var.instance_tags

  // If this resource were ever created accidentally, do not boot it before
  // the imported role's actual permissions have converged.
  depends_on = [
    aws_iam_role_policy.inline,
    aws_iam_role_policy_attachment.managed,
  ]
}
