# Quill Cloud on GCP Confidential Space

Bring-up scripts for the GCP-hosted, Confidential-Space-attested
counterpart to the AWS Nitro Enclaves deploy in `envs/prod/`. Same
trust property (TLS terminates inside the attested workload, the four-
binding chain commits to image_digest + cert + device-blob + nonce),
different signing format (Google-issued OIDC JWT instead of
NSM-signed COSE_Sign1).

The first build runs OpenRouter as the LLM backend (same contractual
ZDR pin to `google-vertex` we use on AWS) because Anthropic-on-Vertex
quota for new GCP accounts takes weeks. Once the quota arrives, swap
the workload image to `Dockerfile.enclave.gcp` (the `llm_vertex`
variant) — same VM, same metadata, just a different OCI ref.

## One-time prereqs

```bash
gcloud auth login
gcloud auth application-default login
gcloud config set project quill-cloud-proxy
```

OpenRouter API key in `~/.quill-openrouter-test.key` (the same path the
AWS smoke test used). `chmod 600`.

## Bring-up

```bash
./bringup.sh
```

That's it. The script is idempotent — re-run it after any tweak. It:

1. Enables APIs (Confidential Computing, Compute, Artifact Registry,
   KMS, Secret Manager, IAM, STS, DNS).
2. Creates Artifact Registry repo `quill` in `us-central1`.
3. Creates the workload service account.
4. Creates KMS keyring + key for attestation-condition gating.
5. Creates the OpenRouter + device-keys secrets in Secret Manager,
   grants `roles/secretmanager.secretAccessor` to the workload SA.
6. Builds + pushes `enclave-openrouter:latest` from
   `quill-cloud-proxy/enclave-go/Dockerfile.enclave.gcp.openrouter`.
7. Creates the Confidential Space VM (`n2d-standard-2`, AMD SEV-SNP,
   shielded boot/vTPM/integrity) with `tee-image-reference` pointing at
   the image just pushed.
8. Opens firewall ingress on `tcp:8001`.
9. Prints the public IP and a curl-it smoke-test recipe.

Cost: ~$60/mo for the VM (n2d-standard-2 24/7), pennies for everything
else. The first $300 of GCP credit covers ~5 months.

## DNS

Add a Cloudflare A record (DNS-only, NOT proxied — we need TCP
passthrough to the workload):

```
api-gcp.quill.lorehex.co  A  <IP from bringup.sh output>
```

## Trust property

| Hop | Property |
|---|---|
| Client → GCE network | TLS, hostname pinned to api-gcp.quill.lorehex.co |
| GCE network → VM | TCP-only; no termination outside the workload |
| VM → workload | TLS terminates **inside** the attested container |
| Workload → OpenRouter | TLS, contractual ZDR via `provider.data_collection: deny` + `provider.only: ["google-vertex"]` |

Stronger than the AWS V1 in one respect: **no parent process** sees the
device blob or the OpenRouter key in plaintext at boot. Confidential
Space runs the workload as the only thing on the box; it pulls the
secrets directly from Secret Manager via Workload Identity, gated by
KMS attestation condition (image_digest must match).

## Teardown

```bash
./teardown.sh
```

Removes the VM + secrets + firewall + service account. Preserves KMS
keys (24h-7d destroy window means deletes aren't useful for this
horizon) and the Artifact Registry repo (cheap, keeps the image for
revival).

## Files

- `bringup.sh` — provisioning script (gcloud-only, no Terraform yet)
- `teardown.sh` — symmetric teardown
- `README.md` — this file

## Why no Terraform?

For V1, the imperative gcloud script was 30 minutes vs ~4 hours of
Terraform module work, and "delete-everything-and-recreate" is
literally one command. We can promote to Terraform once the shape is
stable. The AWS side runs Terraform because we needed multi-resource
diffing while iterating on the Nitro/EIF/parent dance; the CSP side
is a single VM + a few aux resources, so the simpler tool fits.
