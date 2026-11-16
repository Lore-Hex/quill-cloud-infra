# GitHub Actions OIDC identity provider for this AWS account.
#
# The provider is shared: GitHub deploy roles managed outside this repo
# (quill-router infra/) federate through it, so it must never be destroyed or
# replaced from here. No long-lived AWS keys ever live in GitHub secrets.
#
# This module used to create a `quill-deploy` role as well. It was retired on
# 2026-11-16 and no longer exists in AWS. It trusted pull_request tokens as
# well as pushes to main and carried AdministratorAccess, so any pull-request
# workflow in the trusted repos could act as an account administrator. Do not
# bring it back: GitHub workflows use main-only roles.
#
# The removed blocks below take the role and its two policy attachments out of
# Terraform state without destroying anything (there is nothing left to
# destroy). While they exist, declaring any of those addresses again makes
# plan fail with "Removed resource still exists".

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  # GitHub's OIDC root CA fingerprints. AWS recommends pinning these.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  lifecycle {
    prevent_destroy = true
    # The live provider was recreated on 2026-08-02 outside this repo, with a
    # different thumbprint and its own tags, and three main-only roles managed
    # elsewhere depend on it. AWS ignores configured thumbprints for GitHub,
    # so leave those values to whoever owns the live provider.
    ignore_changes = [thumbprint_list, tags, tags_all]
  }
}

removed {
  from = aws_iam_role.deploy

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role_policy_attachment.deploy_ecr

  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role_policy_attachment.deploy_admin

  lifecycle {
    destroy = false
  }
}
