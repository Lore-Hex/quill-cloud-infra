#!/usr/bin/env bash
# Tear down everything created by bringup.sh. Idempotent. Useful for
# blowing away a dirty state during early provisioning.
#
# Does NOT delete: KMS keys (those have an enforced 24h-7d destroy window
# in GCP and are pennies to keep), Artifact Registry repo (cheap, keeps
# images for revival), the GCP project itself.

set -uo pipefail

PROJECT_ID="${PROJECT_ID:-quill-cloud-proxy}"
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-us-central1-a}"
VM_NAME="${VM_NAME:-quill-enclave}"
SECRET_OPENROUTER="${SECRET_OPENROUTER:-quill-openrouter-key}"
SECRET_DEVICES="${SECRET_DEVICES:-quill-device-keys}"
WORKLOAD_SA="${WORKLOAD_SA_NAME:-quill-workload}@$PROJECT_ID.iam.gserviceaccount.com"

gc() { gcloud --project "$PROJECT_ID" "$@"; }

set -x
gc compute instances delete "$VM_NAME" --zone="$ZONE" --quiet 2>/dev/null || true
gc compute firewall-rules delete quill-allow-lb-health quill-allow-public-tls --quiet 2>/dev/null || true
gc secrets delete "$SECRET_OPENROUTER" --quiet 2>/dev/null || true
gc secrets delete "$SECRET_DEVICES" --quiet 2>/dev/null || true
gc iam service-accounts delete "$WORKLOAD_SA" --quiet 2>/dev/null || true
echo "teardown done. KMS, Artifact Registry, and the project itself were preserved."
