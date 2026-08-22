#!/usr/bin/env bash
# Adopt the live GCP analytics cluster into Terraform state.
#
# Every resource this root module describes already EXISTS. It was provisioned
# before this configuration, which is the normal state of affairs for
# infrastructure that predates its own Terraform. So the first thing that
# happens here is an import, not an apply.
#
# The failure mode this prevents is not subtle: `terraform apply` against an
# empty state would CREATE a second service account, firewall rules and three
# ClickHouse machines beside the cluster holding the data, then leave two
# competing layouts with no trustworthy owner. Each node's disk IS one third
# of the analytics store.
#
# Safe to re-run: anything already in state is skipped, and anything absent from
# GCP is reported rather than imported.
#
# Usage:
#   PROJECT_ID=quill-cloud-proxy bash envs/gcp-prod/import.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

PROJECT_ID="${PROJECT_ID:-quill-cloud-proxy}"
SERVICE_ACCOUNT_EMAIL="tr-clickhouse@${PROJECT_ID}.iam.gserviceaccount.com"

# Snapshot state ONCE. Re-running `terraform state list` per resource and
# discarding its stderr makes an error -- a held lock, a backend problem --
# indistinguishable from "not in state", and the script then imports something
# it already manages.
STATE="$(terraform state list)" || {
  echo "terraform state list failed; refusing to guess what is already managed" >&2
  exit 1
}

adopt() {
  local addr="$1" id="$2"
  if printf '%s\n' "$STATE" | grep -qxF "$addr"; then
    echo "  already in state: ${addr}"
    return
  fi
  if [ -z "$id" ]; then
    echo "  not in GCP, terraform apply would create it: ${addr}"
    return
  fi
  terraform import -input=false \
    -var "project_id=${PROJECT_ID}" \
    "$addr" "$id" >/dev/null && {
      STATE="${STATE}"$'\n'"$addr"
      echo "  imported: ${addr}"
    }
}

service_account_import_id() {
  if gcloud iam service-accounts describe "$SERVICE_ACCOUNT_EMAIL" \
    --project "$PROJECT_ID" >/dev/null 2>&1; then
    printf 'projects/%s/serviceAccounts/%s' "$PROJECT_ID" "$SERVICE_ACCOUNT_EMAIL"
  fi
}

firewall_import_id() {
  local name="$1"
  if gcloud compute firewall-rules describe "$name" \
    --project "$PROJECT_ID" >/dev/null 2>&1; then
    printf 'projects/%s/global/firewalls/%s' "$PROJECT_ID" "$name"
  fi
}

instance_import_id() {
  local name="$1" zone="$2"
  if gcloud compute instances describe "$name" \
    --project "$PROJECT_ID" --zone "$zone" >/dev/null 2>&1; then
    printf 'projects/%s/zones/%s/instances/%s' "$PROJECT_ID" "$zone" "$name"
  fi
}

echo "=== GCP analytics identity and firewall"
adopt 'module.clickhouse.google_service_account.clickhouse' \
  "$(service_account_import_id)"
adopt 'module.clickhouse.google_compute_firewall.internal' \
  "$(firewall_import_id tr-clickhouse-internal)"
adopt 'module.clickhouse.google_compute_firewall.health_check' \
  "$(firewall_import_id tr-clickhouse-health-check)"

echo "=== GCP analytics nodes"
adopt 'module.clickhouse.google_compute_instance.node["tr-clickhouse-1"]' \
  "$(instance_import_id tr-clickhouse-1 us-central1-a)"
adopt 'module.clickhouse.google_compute_instance.node["tr-clickhouse-2"]' \
  "$(instance_import_id tr-clickhouse-2 us-central1-b)"
adopt 'module.clickhouse.google_compute_instance.node["tr-clickhouse-3"]' \
  "$(instance_import_id tr-clickhouse-3 us-central1-c)"

echo
echo "=== drift (expect: no changes, or additions you can explain)"
terraform plan -input=false -no-color \
  -var "project_id=${PROJECT_ID}" \
  2>&1 | tail -6
