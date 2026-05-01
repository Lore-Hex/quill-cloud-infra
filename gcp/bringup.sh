#!/usr/bin/env bash
# Quill Cloud — GCP Confidential Space bring-up.
#
# Runs end-to-end: enables APIs, creates Artifact Registry, KMS, Secret
# Manager secrets, the Confidential Space VM, and a global L4 TCP load
# balancer, prints the public IP at the end.
#
# Idempotent: every step is `describe-or-create`; safe to re-run.
#
# Prerequisites (already done if you've used gcloud once):
#   gcloud auth login
#   gcloud auth application-default login
#   gcloud config set project quill-cloud-proxy
#
# Inputs (env, all optional):
#   PROJECT_ID    default: quill-cloud-proxy
#   REGION        default: us-central1   (Confidential Space + AMD SEV-SNP availability)
#   ZONE          default: us-central1-a
#   REPO          default: quill         (Artifact Registry repo)
#   IMAGE         default: enclave-openrouter:latest
#   VM_NAME       default: quill-enclave
#   SECRET_OPENROUTER_FILE   path to a file with the OpenRouter API key
#                              (default: ~/.quill-openrouter-test.key — same path
#                               we used for the AWS smoke test)
#   SECRET_DEVICES_FILE      path to a JSON file shaped like
#                              [{"key_hash":"<hex>","owner":"...","device_id":"q-001"}, ...]
#                              (default: generated fresh with one device q-001)

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-quill-cloud-proxy}"
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-us-central1-a}"
REPO="${REPO:-quill}"
IMAGE_NAME="${IMAGE_NAME:-enclave-openrouter}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
VM_NAME="${VM_NAME:-quill-enclave}"
WORKLOAD_SA_NAME="${WORKLOAD_SA_NAME:-quill-workload}"
SECRET_OPENROUTER="${SECRET_OPENROUTER:-quill-openrouter-key}"
SECRET_DEVICES="${SECRET_DEVICES:-quill-device-keys}"
SECRET_OPENROUTER_FILE="${SECRET_OPENROUTER_FILE:-$HOME/.quill-openrouter-test.key}"
KEYRING="${KEYRING:-quill}"
KMS_KEY="${KMS_KEY:-quill-attest}"
LB_NAME="${LB_NAME:-quill-prompt}"
HEALTH_CHECK="${HEALTH_CHECK:-quill-health}"
BACKEND_SERVICE="${BACKEND_SERVICE:-quill-backend}"
INSTANCE_GROUP="${INSTANCE_GROUP:-quill-ig}"
FORWARD_RULE="${FORWARD_RULE:-quill-fr}"

# ---- helpers -----------------------------------------------------------
log() { echo "[$(date +%H:%M:%S)] $*" >&2; }
gc() { gcloud --project "$PROJECT_ID" "$@"; }

# ---- 0. Sanity: gcloud auth -------------------------------------------
if ! gc projects describe "$PROJECT_ID" --format='value(projectNumber)' >/tmp/.proj 2>&1; then
  if grep -q -i 'reauthentication\|reauth\|login' /tmp/.proj; then
    cat <<'EOF' >&2

Your gcloud session needs a fresh login. Run:

  gcloud auth login
  gcloud auth application-default login

Then re-run this script.

EOF
    rm -f /tmp/.proj
    exit 1
  fi
  cat /tmp/.proj >&2
  rm -f /tmp/.proj
  exit 1
fi
PROJECT_NUMBER=$(cat /tmp/.proj | tr -d '\n')
rm -f /tmp/.proj
log "project: $PROJECT_ID ($PROJECT_NUMBER)"

# ---- 1. APIs -----------------------------------------------------------
log "enabling APIs..."
gc services enable \
  confidentialcomputing.googleapis.com \
  compute.googleapis.com \
  artifactregistry.googleapis.com \
  cloudkms.googleapis.com \
  secretmanager.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  dns.googleapis.com

# ---- 2. Artifact Registry ---------------------------------------------
if ! gc artifacts repositories describe "$REPO" --location "$REGION" >/dev/null 2>&1; then
  log "creating Artifact Registry $REPO in $REGION..."
  gc artifacts repositories create "$REPO" \
    --repository-format=docker \
    --location="$REGION" \
    --description="Quill Cloud workload images"
else
  log "Artifact Registry $REPO already exists"
fi
ARTIFACT_HOST="$REGION-docker.pkg.dev"
IMAGE_REF="$ARTIFACT_HOST/$PROJECT_ID/$REPO/$IMAGE_NAME:$IMAGE_TAG"
log "image will be: $IMAGE_REF"

# ---- 3. Workload service account --------------------------------------
WORKLOAD_SA="$WORKLOAD_SA_NAME@$PROJECT_ID.iam.gserviceaccount.com"
if ! gc iam service-accounts describe "$WORKLOAD_SA" >/dev/null 2>&1; then
  log "creating workload SA $WORKLOAD_SA..."
  gc iam service-accounts create "$WORKLOAD_SA_NAME" \
    --display-name="Quill Cloud workload (Confidential Space)"
else
  log "workload SA $WORKLOAD_SA already exists"
fi

# ---- 4. KMS keyring + key ---------------------------------------------
if ! gc kms keyrings describe "$KEYRING" --location "$REGION" >/dev/null 2>&1; then
  log "creating KMS keyring $KEYRING..."
  gc kms keyrings create "$KEYRING" --location="$REGION"
fi
if ! gc kms keys describe "$KMS_KEY" --keyring "$KEYRING" --location "$REGION" >/dev/null 2>&1; then
  log "creating KMS key $KMS_KEY..."
  gc kms keys create "$KMS_KEY" \
    --keyring="$KEYRING" \
    --location="$REGION" \
    --purpose=encryption
else
  log "KMS key $KMS_KEY already exists"
fi

# ---- 5. Secret Manager secrets ----------------------------------------
ensure_secret() {
  local name="$1" value="$2"
  if ! gc secrets describe "$name" >/dev/null 2>&1; then
    log "creating secret $name (initial version)..."
    printf '%s' "$value" | gc secrets create "$name" \
      --replication-policy=automatic \
      --data-file=-
  else
    # If file content differs from current, add a new version.
    local current
    current=$(gc secrets versions access latest --secret="$name" 2>/dev/null || echo "")
    if [ "$current" != "$value" ]; then
      log "secret $name content changed — adding new version"
      printf '%s' "$value" | gc secrets versions add "$name" --data-file=-
    else
      log "secret $name unchanged"
    fi
  fi
  gc secrets add-iam-policy-binding "$name" \
    --member="serviceAccount:$WORKLOAD_SA" \
    --role="roles/secretmanager.secretAccessor" \
    --condition=None >/dev/null
}

if [ ! -f "$SECRET_OPENROUTER_FILE" ]; then
  echo "ERROR: SECRET_OPENROUTER_FILE missing: $SECRET_OPENROUTER_FILE" >&2
  echo "Put your OpenRouter API key in that file (chmod 600), then re-run." >&2
  exit 1
fi
OPENROUTER_KEY=$(tr -d '[:space:]' < "$SECRET_OPENROUTER_FILE")
ensure_secret "$SECRET_OPENROUTER" "$OPENROUTER_KEY"
unset OPENROUTER_KEY

# Generate a fresh device-key blob if not provided.
SECRET_DEVICES_FILE="${SECRET_DEVICES_FILE:-$HOME/.quill-gcp-device-keys.json}"
SECRET_DEVICES_BEARER_FILE="$HOME/.quill-gcp-q-001-bearer.txt"
if [ ! -f "$SECRET_DEVICES_FILE" ]; then
  log "generating fresh device keys (one device: q-001)..."
  python3 - <<'PY' "$SECRET_DEVICES_FILE" "$SECRET_DEVICES_BEARER_FILE"
import hashlib, json, secrets, sys, os
out_blob, out_bearer = sys.argv[1], sys.argv[2]
key = secrets.token_urlsafe(32)
devices = [{
  "key_hash": hashlib.sha256(key.encode()).hexdigest(),
  "owner": "you@quill",
  "device_id": "q-001",
}]
os.makedirs(os.path.dirname(out_blob) or ".", exist_ok=True)
with open(out_blob, "w") as f: json.dump(devices, f, separators=(",", ":"))
os.chmod(out_blob, 0o600)
with open(out_bearer, "w") as f: f.write(key + "\n")
os.chmod(out_bearer, 0o600)
print(f"wrote {out_blob} (1 device)")
print(f"wrote {out_bearer} (bearer; chmod 600)")
PY
fi
DEVICES_JSON=$(cat "$SECRET_DEVICES_FILE")
ensure_secret "$SECRET_DEVICES" "$DEVICES_JSON"
unset DEVICES_JSON

# ---- 6. Build + push the workload image -------------------------------
# Re-use the existing Dockerfile.enclave.gcp.openrouter from the proxy repo.
PROXY_DIR="${PROXY_DIR:-$HOME/claude/quill-cloud-proxy}"
if [ ! -d "$PROXY_DIR/enclave-go" ]; then
  echo "ERROR: PROXY_DIR not found ($PROXY_DIR). Set PROXY_DIR to your quill-cloud-proxy checkout." >&2
  exit 1
fi
log "configuring docker auth for $ARTIFACT_HOST..."
gcloud auth configure-docker "$ARTIFACT_HOST" --quiet >/dev/null

# Skip the build if the image already exists with the desired tag.
if gc artifacts docker images describe "$IMAGE_REF" >/dev/null 2>&1; then
  log "image $IMAGE_REF already exists in Artifact Registry — skipping build"
else
  log "building $IMAGE_REF (linux/amd64, scratch)..."
  ( cd "$PROXY_DIR/enclave-go" && \
    docker buildx build \
      --platform linux/amd64 \
      --file Dockerfile.enclave.gcp.openrouter \
      --tag "$IMAGE_REF" \
      --push \
      . )
fi
IMAGE_DIGEST=$(gc artifacts docker images describe "$IMAGE_REF" --format='value(image_summary.digest)')
log "image digest: $IMAGE_DIGEST"

# ---- 7. Confidential Space VM ----------------------------------------
# Use the Google-published Confidential Space launcher image. The launcher
# embeds the workload OCI ref via tee-* metadata (set below).
LAUNCHER_IMAGE="confidential-space-debug"  # debug variant prints workload logs to console
LAUNCHER_PROJECT="confidential-space-images"

# Single-instance singleton — V1, no HA.
if ! gc compute instances describe "$VM_NAME" --zone "$ZONE" >/dev/null 2>&1; then
  log "creating Confidential Space VM $VM_NAME..."
  gc compute instances create "$VM_NAME" \
    --zone="$ZONE" \
    --machine-type="n2d-standard-2" \
    --confidential-compute-type="SEV_SNP" \
    --maintenance-policy="TERMINATE" \
    --service-account="$WORKLOAD_SA" \
    --scopes="https://www.googleapis.com/auth/cloud-platform" \
    --image-family="$LAUNCHER_IMAGE" \
    --image-project="$LAUNCHER_PROJECT" \
    --shielded-secure-boot \
    --shielded-vtpm \
    --shielded-integrity-monitoring \
    --tags="quill-enclave" \
    --metadata="^~^tee-image-reference=$IMAGE_REF~tee-restart-policy=Always~tee-container-log-redirect=true~tee-env-QUILL_GCP_PROJECT_ID=$PROJECT_ID~tee-env-QUILL_GCP_REGION=$REGION~tee-env-QUILL_DEVICE_KEYS_SECRET=$SECRET_DEVICES~tee-env-QUILL_OPENROUTER_SECRET=$SECRET_OPENROUTER~tee-env-QUILL_ENCLAVE_TLS=true"
else
  log "VM $VM_NAME already exists — updating metadata"
  gc compute instances add-metadata "$VM_NAME" \
    --zone="$ZONE" \
    --metadata="tee-image-reference=$IMAGE_REF,tee-restart-policy=Always,tee-container-log-redirect=true,tee-env-QUILL_GCP_PROJECT_ID=$PROJECT_ID,tee-env-QUILL_GCP_REGION=$REGION,tee-env-QUILL_DEVICE_KEYS_SECRET=$SECRET_DEVICES,tee-env-QUILL_OPENROUTER_SECRET=$SECRET_OPENROUTER,tee-env-QUILL_ENCLAVE_TLS=true"
fi

# ---- 8. Firewall: allow GLB health checks + :8001 ingress -------------
if ! gc compute firewall-rules describe quill-allow-lb-health >/dev/null 2>&1; then
  log "creating firewall rule for GLB health checks..."
  gc compute firewall-rules create quill-allow-lb-health \
    --network="default" \
    --action=ALLOW \
    --direction=INGRESS \
    --source-ranges="35.191.0.0/16,130.211.0.0/22" \
    --rules="tcp:8001" \
    --target-tags="quill-enclave"
fi
if ! gc compute firewall-rules describe quill-allow-public-tls >/dev/null 2>&1; then
  log "creating firewall rule for public TLS-passthrough..."
  gc compute firewall-rules create quill-allow-public-tls \
    --network="default" \
    --action=ALLOW \
    --direction=INGRESS \
    --source-ranges="0.0.0.0/0" \
    --rules="tcp:8001" \
    --target-tags="quill-enclave"
fi

# ---- 9. Public IP + DNS ----------------------------------------------
# For V1 we just publish the VM's external IP; the user adds an A record
# in Cloudflare DNS for api-gcp.quill.lorehex.co. (Skipping the L4 GLB
# for the first cut — direct VM IP is simpler and TCP passthrough on
# :8001 is what the workload expects anyway.)
EXTERNAL_IP=$(gc compute instances describe "$VM_NAME" --zone="$ZONE" \
  --format='value(networkInterfaces[0].accessConfigs[0].natIP)')

cat <<EOF

──────────────────────────────────────────────────────────────────────
Quill Cloud GCP bring-up complete.

VM:                 $VM_NAME ($ZONE)
Public IP:          $EXTERNAL_IP
Image:              $IMAGE_REF
Image digest:       $IMAGE_DIGEST
Bearer (q-001):     $SECRET_DEVICES_BEARER_FILE   (chmod 600)

Next steps:
  1. Add A record in Cloudflare DNS:
       api-gcp.quill.lorehex.co  →  $EXTERNAL_IP   (DNS-only, NOT proxied)

  2. Wait ~3-5 min for the Confidential Space launcher to pull the
     workload image and start it. Watch logs:
       gcloud compute instances get-serial-port-output $VM_NAME --zone=$ZONE | tail -200

  3. Smoke test:
       curl -sS -k https://$EXTERNAL_IP:8001/attestation -o /tmp/att.bin
       BEARER=\$(cat $SECRET_DEVICES_BEARER_FILE | tr -d '[:space:]')
       curl -sS -k -N "https://$EXTERNAL_IP:8001/v1/chat/completions" \\
         -H "Host: api-gcp.quill.lorehex.co" \\
         -H "Authorization: Bearer \$BEARER" \\
         -H "content-type: application/json" \\
         -d '{"model":"claude-opus-4-7","stream":true,
              "messages":[{"role":"user","content":"reply PONG"}]}'

  4. Once smoke passes, bump trust-page/pcr0.txt → image_digest from above
     (and rename to image-digest-gcp.txt or similar; one-line diff).

──────────────────────────────────────────────────────────────────────
EOF
