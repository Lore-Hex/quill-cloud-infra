# GitHub OIDC trust + a single deploy role assumable by quill-cloud-{proxy,infra}.
# CI uses sts:AssumeRoleWithWebIdentity to get short-lived AWS creds.
# No long-lived AWS keys ever live in GitHub secrets.

variable "github_repos" { type = list(string) }

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # GitHub's OIDC root CA fingerprints. AWS recommends pinning these.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_policy_document" "github_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    # Restrict to our specific repos and to push events on main + PRs.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = flatten([
        for repo in var.github_repos : [
          "repo:${repo}:ref:refs/heads/main",
          "repo:${repo}:pull_request",
        ]
      ])
    }
  }
}

resource "aws_iam_role" "deploy" {
  name               = "quill-deploy"
  assume_role_policy = data.aws_iam_policy_document.github_trust.json
}

# The deploy role gets a managed policy for ECR push + ECS update + Terraform
# apply. Keep this scoped; this is the broadest IAM in the account.
resource "aws_iam_role_policy_attachment" "deploy_ecr" {
  role       = aws_iam_role.deploy.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}

# TODO(v1.1): replace AdministratorAccess with a tightly-scoped custom policy
#  that only allows updates to the modules in this infra repo. For V1 with
#  a small operator base, this is acceptable but flagged.
resource "aws_iam_role_policy_attachment" "deploy_admin" {
  role       = aws_iam_role.deploy.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

output "deploy_role_arn" { value = aws_iam_role.deploy.arn }
