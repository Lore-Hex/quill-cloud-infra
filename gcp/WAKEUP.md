# Wake-up notes — GCP Confidential Space deploy

Hi. I got blocked on `gcloud auth login` (interactive, can't drive
while you sleep) so the live GCP deploy didn't happen. Everything
*else* did. Here's the state:

## What I did while you slept

### `quill-cloud-proxy` repo

- **PR #20 open**: refactors build tags from `aws|gcp|openrouter` →
  two orthogonal axes `cloud_aws|cloud_gcp` × `llm_bedrock|llm_vertex|llm_openrouter`.
  Adds the `cloud_gcp` siblings — `bootstrap_gcp.go`, `attestation_gcp.go`,
  `entropy_gcp.go`, `listener_gcp.go`, `error_classifier_gcp.go`,
  `openrouter_transport_gcp.go`. New `Dockerfile.enclave.gcp.openrouter`.
  CI matrix runs all four combos. **All four combos build + test
  locally.** Untested in prod yet.
- Live AWS: ASG=0, ALB+NLB+EC2+launch-template all destroyed via
  `terraform apply -destroy -target=module.{compute,alb,nlb}`. Network
  module (VPC + NAT) preserved for cheap revival ($38/mo idle).
- Trust page still shows the old AWS PCR0 — you said hold off until
  direct-Vertex.

### `quill-cloud-infra` repo

- New `gcp/` directory:
  - `gcp/bringup.sh` — idempotent shell script that does the full GCP
    provision via `gcloud`. APIs, Artifact Registry, KMS, Secret
    Manager, workload SA, build+push image, Confidential Space VM,
    firewall.
  - `gcp/teardown.sh` — symmetric teardown.
  - `gcp/README.md` — explains the trust model + costs.
- (Branch: `feat/gcp-confidential-space`. Not pushed yet — pushed once
  the smoke is green so the diff is "this is what worked".)

### `quill` repo

- **PR #1** (`feat/usb-tether-upstream-fallback`) — Pi can use the Mac's
  internet via USB tether when Wi-Fi is unavailable. CI was failing on
  an unrelated `ruff UP017` (datetime.utcnow → datetime.UTC); fixed in a
  follow-up commit. Hasn't been merged because it wants a real-hardware
  test.
- **SD card prepped**: when you plugged in `/Volumes/bootfs` I ran
  `./provisioning/prep-sd-card.sh q-001`. The SD has the latest
  `firstrun.sh` (with USB-tether failover) and a per-device cert. Eject
  + insert in the Pi when you're ready. Cert valid until 2028-08-03.

## What you do in the morning (≤ 2 commands)

```bash
# 1. Re-auth gcloud
gcloud auth login
gcloud auth application-default login
gcloud config set project quill-cloud-proxy

# 2. Run bring-up (idempotent — safe to re-run)
cd ~/claude/quill-cloud-infra/gcp
./bringup.sh
```

The script will:
1. Enable APIs
2. Create Artifact Registry repo + workload SA + KMS key + secrets
3. Build + push the workload image to `us-central1-docker.pkg.dev`
4. Create the Confidential Space VM (`n2d-standard-2`, AMD SEV-SNP)
5. Open firewall on `tcp:8001`
6. Print the VM's public IP + a curl-it smoke recipe

Then add a Cloudflare DNS A record `api-gcp.quill.lorehex.co → <IP>`
(DNS-only, NOT proxied). Smoke test recipe is in the bring-up output.

## Open questions to think about

1. **Anthropic-on-Vertex quota** — request it via Vertex Model Garden
   for `claude-opus-4.7`. Once it arrives, swap the build tag to
   `cloud_gcp,llm_vertex` and you have first-party-attested-everything,
   no OpenRouter hop.
2. **Pi's upstream is `api.anthropic.com`, not Quill Cloud** — the Pi
   doesn't currently talk to api.quill.lorehex.co at all (it has its
   own Claude API key). Routing the Pi *through* Quill Cloud is a
   separate piece of work (config + auth + adapter changes). Worth
   doing eventually for "every Quill device's prompts go through
   attested infra" but explicitly out of this round's scope.
3. **AWS network module** still costs ~$38/mo idle. To stop that:
   `terraform apply -destroy -target=module.network` from the AWS
   `envs/prod/` directory.

## Files for context

- Bring-up script:    `gcp/bringup.sh`
- Teardown script:    `gcp/teardown.sh`
- README + trust:     `gcp/README.md`
- Proxy refactor PR:  https://github.com/Lore-Hex/quill-cloud-proxy/pull/20
- Pi USB failover PR: https://github.com/Lore-Hex/quill/pull/1

If anything looks off, the smoke-test recipe at the bottom of
`bringup.sh`'s output is the fastest way to know if it's actually
working. Should stream `PONG` from `claude-opus-4-7` via OpenRouter →
google-vertex ZDR exactly the way the AWS deploy did before we tore it
down.
