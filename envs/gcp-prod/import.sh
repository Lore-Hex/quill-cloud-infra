#!/usr/bin/env bash
# Adopt the live GCP analytics cluster and static enclave-fleet layout into
# Terraform state.
#
# Every resource this root module describes already EXISTS. It was provisioned
# before this configuration, which is the normal state of affairs for
# infrastructure that predates its own Terraform. So the first thing that
# happens here is an import, not an apply.
#
# The failure mode this prevents is not subtle: `terraform apply` against an
# empty state would CREATE duplicate service accounts, firewall rules, regional
# MIG shells and ClickHouse machines beside production, then leave two competing
# layouts with no trustworthy owner. Each ClickHouse node's disk IS one third of
# the analytics store; deleting a MIG is an outage in that region.
#
# Safe to re-run: anything already in state is skipped, and anything absent from
# GCP is reported rather than imported.
#
# Usage:
#   PROJECT_ID=quill-cloud-proxy bash envs/gcp-prod/import.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

PROJECT_ID="${PROJECT_ID:-quill-cloud-proxy}"
CLICKHOUSE_SERVICE_ACCOUNT_EMAIL="tr-clickhouse@${PROJECT_ID}.iam.gserviceaccount.com"
WORKLOAD_SERVICE_ACCOUNT_EMAIL="quill-workload@${PROJECT_ID}.iam.gserviceaccount.com"

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

# Each helper answers "what is this resource's import id", with THREE possible
# outcomes, not two: present (prints the id), absent (prints nothing, exits 0),
# and COULD NOT ASK (message on stderr, exits 1). The first version collapsed
# the last two -- every describe was guarded by >/dev/null 2>&1 -- so an
# expired credential or a disabled API read as "not in GCP, terraform apply
# would create it". That is the same empty-means-absent trap the snapshot
# comment above already warns about, on the other side of the conversation.
# gcloud's CLI auth and Terraform's application-default credentials can also
# diverge, so the script could claim absence while an apply, authenticated
# differently, went on to collide with the live resources.
#
# Callers assign these via VAR="$(helper)" as standalone assignments, where the
# substitution's exit status IS the assignment's status and `set -e` stops the
# script. Nesting the call inside another command's arguments would discard
# that status.
probe() {
  local what="$1"; shift
  local out
  if out="$(gcloud "$@" --project "$PROJECT_ID" 2>&1)"; then
    return 0
  fi
  if printf '%s' "$out" | grep -qiE "NOT_FOUND|was not found|does not exist"; then
    return 10
  fi
  printf 'could not ask GCP about %s:\n%s\n' "$what" "$out" >&2
  return 1
}

service_account_import_id() {
  local email="$1"
  probe "$email" iam service-accounts describe "$email" \
    && printf 'projects/%s/serviceAccounts/%s' "$PROJECT_ID" "$email" \
    || { [ $? -eq 10 ] && return 0 || return 1; }
}

firewall_import_id() {
  local name="$1"
  probe "firewall $name" compute firewall-rules describe "$name" \
    && printf 'projects/%s/global/firewalls/%s' "$PROJECT_ID" "$name" \
    || { [ $? -eq 10 ] && return 0 || return 1; }
}

instance_import_id() {
  local name="$1" zone="$2"
  probe "instance $name" compute instances describe "$name" --zone "$zone" \
    && printf 'projects/%s/zones/%s/instances/%s' "$PROJECT_ID" "$zone" "$name" \
    || { [ $? -eq 10 ] && return 0 || return 1; }
}

regional_mig_import_id() {
  local name="$1" region="$2"
  probe "regional MIG $name" compute instance-groups managed describe "$name" --region "$region" \
    && printf 'projects/%s/regions/%s/instanceGroupManagers/%s' "$PROJECT_ID" "$region" "$name" \
    || { [ $? -eq 10 ] && return 0 || return 1; }
}

echo "=== GCP analytics identity and firewall"
SA_ID="$(service_account_import_id "$CLICKHOUSE_SERVICE_ACCOUNT_EMAIL")"
FW_INTERNAL_ID="$(firewall_import_id tr-clickhouse-internal)"
FW_HC_ID="$(firewall_import_id tr-clickhouse-health-check)"
adopt 'module.clickhouse.google_service_account.clickhouse' "$SA_ID"
adopt 'module.clickhouse.google_compute_firewall.internal' "$FW_INTERNAL_ID"
adopt 'module.clickhouse.google_compute_firewall.health_check' "$FW_HC_ID"

echo "=== GCP analytics nodes"
NODE1_ID="$(instance_import_id tr-clickhouse-1 us-central1-a)"
NODE2_ID="$(instance_import_id tr-clickhouse-2 us-central1-b)"
NODE3_ID="$(instance_import_id tr-clickhouse-3 us-central1-c)"
adopt 'module.clickhouse.google_compute_instance.node["tr-clickhouse-1"]' "$NODE1_ID"
adopt 'module.clickhouse.google_compute_instance.node["tr-clickhouse-2"]' "$NODE2_ID"
adopt 'module.clickhouse.google_compute_instance.node["tr-clickhouse-3"]' "$NODE3_ID"

echo "=== GCP enclave static identity and public-TLS firewall"
WORKLOAD_SA_ID="$(service_account_import_id "$WORKLOAD_SERVICE_ACCOUNT_EMAIL")"
PUBLIC_TLS_FW_ID="$(firewall_import_id quill-allow-public-tls)"
adopt 'module.enclave_fleet.google_service_account.workload' "$WORKLOAD_SA_ID"
adopt 'module.enclave_fleet.google_compute_firewall.public_tls' "$PUBLIC_TLS_FW_ID"

echo "=== GCP enclave regional MIG shells"
MIG_US_ID="$(regional_mig_import_id quill-enclave-mig-us us-central1)"
MIG_USEAST4_ID="$(regional_mig_import_id quill-enclave-mig-useast4 us-east4)"
MIG_SA_ID="$(regional_mig_import_id quill-enclave-mig-sa southamerica-east1)"
MIG_EU_ID="$(regional_mig_import_id quill-enclave-mig-eu europe-west4)"
adopt 'module.enclave_fleet.google_compute_region_instance_group_manager.regional["us"]' "$MIG_US_ID"
adopt 'module.enclave_fleet.google_compute_region_instance_group_manager.regional["useast4"]' "$MIG_USEAST4_ID"
adopt 'module.enclave_fleet.google_compute_region_instance_group_manager.regional["sa"]' "$MIG_SA_ID"
adopt 'module.enclave_fleet.google_compute_region_instance_group_manager.regional["eu"]' "$MIG_EU_ID"

echo
echo "=== drift (expect: no changes, or additions you can explain)"
terraform plan -input=false -no-color \
  -var "project_id=${PROJECT_ID}" \
  2>&1 | tail -6
