# quill-cloud-infra

Open-source Terraform that provisions [`quill-cloud-proxy`](https://github.com/Lore-Hex/quill-cloud-proxy)
in AWS (us-east-1).

## What it provisions

| Module          | Purpose                                                                     |
|-----------------|-----------------------------------------------------------------------------|
| `network`       | VPC, public/private subnets, Bedrock VPC Interface Endpoint (PrivateLink). |
| `compute`       | EC2 Auto Scaling Group of Nitro-capable hosts running the parent + enclave.|
| `alb`           | ALB + ACM cert (DNS-validated against Cloudflare-managed `lorehex.co`).     |
| `kms`           | Two CMKs: device-keys-cmk (PCR0-attested decrypt), data-cmk (DDB+S3 SSE).   |
| `ecr`           | Repo for parent + enclave images, AWS Signer signing profile.              |
| `dynamodb`      | `quill_usage` table — see schema below.                                     |
| `iam`           | Parent-host role + GitHub OIDC deploy role, both least-privilege.           |
| `s3`            | Buckets for sealed device-key blob, trust page, ALB access logs.            |
| `github-oidc`   | OIDC provider trust + role assumable by Lore-Hex/quill-cloud-{proxy,infra}.|
| `cloudtrail`    | Multi-region trail with Object Lock, dedicated bucket.                      |

## DynamoDB `quill_usage` schema

```
PK device_id   (S)             "q-002"
SK day         (S, "YYYY-MM-DD")  "2026-04-28"

attrs:
  requests        N
  input_tokens    N
  output_tokens   N
  errors          N
  ttl_epoch       N   (90 days from `day`; DynamoDB auto-deletes)

encryption: KMS data-cmk
PITR: enabled
billing: PAY_PER_REQUEST
```

Per-request `UpdateItem ADD` is the only write path (see
`quill-cloud-proxy/parent/src/quill_parent/usage.py`).

## Bootstrap (one-time, with admin AWS creds)

```bash
# 1. Create the Terraform state bucket + lock table.
aws s3api create-bucket --bucket quill-tf-state-prod --region us-east-1
aws s3api put-bucket-versioning --bucket quill-tf-state-prod \
  --versioning-configuration Status=Enabled
aws dynamodb create-table --table-name quill-tf-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST --region us-east-1

# 2. First apply provisions only the GitHub OIDC trust + deploy role,
#    so subsequent applies can run as that role from CI.
cd envs/prod
terraform init
terraform apply -target=module.github_oidc

# 3. Add the role ARN to GitHub repo secrets:
#    Lore-Hex/quill-cloud-proxy: AWS_DEPLOY_ROLE_ARN
#    Lore-Hex/quill-cloud-infra: AWS_DEPLOY_ROLE_ARN

# 4. Subsequent applies happen via GitHub Actions OIDC.
terraform apply
```

## DNS (Cloudflare, manual)

Create three CNAMEs in the `lorehex.co` zone, **DNS-only (grey-cloud)**:

| Name                              | Target                                              |
|-----------------------------------|-----------------------------------------------------|
| `_<random>.api.quill`             | (ACM validation target, printed by `terraform apply`) |
| `api.quill`                       | `<alb-dns>.us-east-1.elb.amazonaws.com.`             |
| `trust.quill`                     | `<trust-bucket-website>.s3-website-us-east-1.amazonaws.com.` |

Cloudflare proxy MUST be off — orange-cloud breaks the trust story
(Cloudflare would terminate TLS at their edge and see prompt bytes).

## License

Apache 2.0.
