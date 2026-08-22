# quill-cloud-infra

Open-source infrastructure for [`quill-cloud-proxy`](https://github.com/Lore-Hex/quill-cloud-proxy).

## Layout

| Path | Cloud | State backend | Status |
|------|-------|---------------|--------|
| `envs/prod/` + `modules/*` | AWS `us-east-1` | S3 + DynamoDB lock | Terraform |
| `envs/azure-prod/` + `modules/azure/*` | Azure `uaenorth` | Azure Blob (lease lock) | Terraform |
| `envs/gcp-prod/` + `modules/gcp/*`; proxy deploy tools | GCP (four enclave regions; analytics in `us-central1`) | GCS (generation lock) | Terraform (analytics + static enclave layout); deploy tools (measured templates) |

The GCP enclave fleet is deliberately split at the row above. Terraform owns
the **STATIC** half: the four regional MIG shells, workload service account and
public-TLS firewall. `quill-cloud-proxy/tools/deploy-gcp-mig.sh` owns the
**MEASURED** half: instance templates carrying the image digest and attested
metadata rotate on every deploy behind attestation gates `plan`/`apply` cannot
express. Terraform ignores each MIG's template version so it never rolls a
verified measured release backward.

Each cloud keeps its Terraform state in ITS OWN cloud. Putting Azure's state in
the S3 bucket would mean an AWS outage blocks every Azure change — including the
ones you would make to route around AWS — which is the hub dependency the
multi-cloud split exists to avoid, reintroduced through a state file.

Resources that predate their Terraform are **imported, never created**: each env
has an `import.sh`, and applying against an empty state would build a second
copy of live infrastructure beside the one holding the data.

Two things stay outside Terraform on purpose, both because plan/apply cannot
express them:

* **Enclave container groups.** Their measurement changes on essentially every
  deploy, and the Key Vault release policy must be widened *before* the group is
  created and narrowed only *after* a live attestation is verified. A single
  apply that swapped that pin in one step is the documented way to end up with
  no group and no way back.
* **Node bootstrap.** Installing ClickHouse, fetching a password and applying a
  schema is a boot-time sequence with retries, not state to converge on.
  Terraform owns the layout — subnet, NSG, identity, disk, machine.

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

## GCP Confidential Space

The GCP production Terraform root adopts analytics and the static enclave-fleet
layout. Measured template releases remain script-driven:

```bash
cd gcp
./bringup.sh
```

That flow builds the GCP workload image, grants the workload service account the
minimum launcher roles, injects non-secret metadata pointers, and relies on the
image-baked `QUILL_ENCLAVE_TLS=true` setting so TLS cannot be disabled at runtime.

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

Business Source License 1.1. See [`LICENSE`](LICENSE). The source is public
so anyone can read and verify the infrastructure shape behind the trust
surface at https://trust.trustedrouter.com. Non-production use (review,
audit, local evaluation) is free. Production use requires a commercial
license from Lore Hex Corp: licensing@trustedrouter.com. Each version
converts to the Apache License 2.0 four years after publication. Code
published before July 3, 2026 remains Apache-2.0.
